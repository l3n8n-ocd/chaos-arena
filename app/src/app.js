'use strict';
// =============================================================================
// app.js — the web API of Chaos Arena (Express).
//
//   GET  /api/health        quick "am I alive?" check (used by monitoring)
//   GET  /api/status        deep check: database + storage reachable?
//   GET  /api/state         everything the web page needs to draw the game
//   POST /api/pull          a team pulls the rope
//   POST /api/chaos         crash the server ON PURPOSE (then it self-heals)
//   POST /api/admin/reset   reset the scores (needs the secret ADMIN_TOKEN)
// =============================================================================

const crypto = require('node:crypto');
const path = require('node:path');
const express = require('express');
const { TEAMS } = require('./game');
const { createRateLimiter } = require('./rate-limit');

const MAX_CLICKS_PER_REQUEST = 8; // the page batches fast clicks into one request
const SAVE_INTERVAL_MS = 3000; // write the game to the database at most every 3 s
const PLAYER_ONLINE_MS = 10000; // a player counts as "online" for 10 s after their last request
const OUTLIER_RECOVERY_MS = 5 * 60 * 1000; // ignore huge values (e.g. server was switched off) in averages

function createArena({ config, game, store, backup, logger, crash, now = Date.now }) {
  const bootId = crypto.randomBytes(4).toString('hex'); // changes on every restart
  const startedAt = now();

  let incidents = []; // newest first, kept in memory so /api/state never hits the database
  let lastRound = null;
  let dirty = false; // "the game changed since the last save"
  let crashing = false;
  let saveTimer = null;
  let cleanupTimer = null;
  let statusCache = { at: 0, body: null };

  const players = new Map(); // playerId -> { team, seenAt }
  const perPlayer = createRateLimiter({ ratePerSec: 16, burst: 32, now });
  const perIp = createRateLimiter({ ratePerSec: 200, burst: 400, now });

  // ---------------------------------------------------------------------------
  // Start-up: load the saved game and finish any "open" incident.
  // An open incident means: CHAOS was pressed, the crash was written to the
  // database, and then the process died. Now that we are running again, we can
  // measure how long the recovery took.
  // ---------------------------------------------------------------------------
  async function init() {
    const saved = await store.loadState();
    if (saved) game.restore(saved);

    incidents = await store.listIncidents(20);
    const rounds = await store.listRounds(1);
    lastRound = rounds[0] || null;

    for (const incident of incidents.filter((i) => i.status === 'open')) {
      const recoveredAt = now();
      incident.status = 'recovered';
      incident.recoveredAt = recoveredAt;
      incident.recoveryMs = recoveredAt - incident.crashedAt;
      await store.putIncident(incident);
      logger.info('recovered from crash', {
        incident: incident.id,
        recoveryMs: incident.recoveryMs,
        round: game.state.round,
      });
      // Fire-and-forget: the backup must not delay the server coming back.
      backup.putJson(`incidents/${incident.id.replace(/[:.]/g, '-')}.json`, incident);
    }

    saveTimer = setInterval(saveIfDirty, SAVE_INTERVAL_MS);
    cleanupTimer = setInterval(() => {
      perPlayer.cleanup();
      perIp.cleanup();
      const cutoff = now() - PLAYER_ONLINE_MS * 6;
      for (const [id, p] of players) if (p.seenAt < cutoff) players.delete(id);
    }, 30000);
    // Timers must not keep the process alive on shutdown.
    saveTimer.unref();
    cleanupTimer.unref();
  }

  async function saveIfDirty() {
    if (!dirty) return;
    dirty = false;
    try {
      await store.saveState(game.snapshot());
    } catch (err) {
      dirty = true; // try again on the next tick
      logger.error('saving game state failed', { error: err.message });
    }
  }

  /** Called on a normal shutdown (deploy/restart): save, then stop the timers. */
  async function stop() {
    clearInterval(saveTimer);
    clearInterval(cleanupTimer);
    await saveIfDirty();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  function cleanPlayerId(value) {
    return typeof value === 'string' && /^[A-Za-z0-9_-]{6,40}$/.test(value) ? value : null;
  }

  function touchPlayer(playerId, team) {
    if (!playerId) return;
    if (!players.has(playerId) && players.size >= 5000) return; // hard cap on memory
    players.set(playerId, { team: TEAMS.includes(team) ? team : null, seenAt: now() });
  }

  function countPlayers() {
    const cutoff = now() - PLAYER_ONLINE_MS;
    const count = { total: 0, red: 0, blue: 0 };
    for (const p of players.values()) {
      if (p.seenAt < cutoff) continue;
      count.total += 1;
      if (p.team) count[p.team] += 1;
    }
    return count;
  }

  function chaosStats() {
    const done = incidents.filter(
      (i) => i.status === 'recovered' && Number.isFinite(i.recoveryMs) && i.recoveryMs < OUTLIER_RECOVERY_MS
    );
    const times = done.map((i) => i.recoveryMs);
    return {
      total: game.state.chaosCount,
      cooldownSec: config.chaosCooldownSec,
      cooldownRemainingSec: game.chaosCooldownRemaining(config.chaosCooldownSec),
      lastRecoveryMs: times.length ? times[0] : null,
      avgRecoveryMs: times.length ? Math.round(times.reduce((a, b) => a + b, 0) / times.length) : null,
      bestRecoveryMs: times.length ? Math.min(...times) : null,
    };
  }

  /** Everything the web page needs, in one small JSON object. */
  function view() {
    const s = game.state;
    return {
      rope: s.rope,
      winAt: game.winAt,
      round: s.round,
      wins: s.wins,
      clicks: s.clicks,
      totalClicks: s.totalClicks,
      roundStartedAt: s.roundStartedAt,
      lastRound,
      players: countPlayers(),
      server: { bootId, startedAt, uptimeSec: Math.floor((now() - startedAt) / 1000), now: now() },
      chaos: chaosStats(),
      incidents: incidents.slice(0, 5).map((i) => ({
        id: i.id,
        crashedAt: i.crashedAt,
        status: i.status,
        recoveryMs: i.recoveryMs ?? null,
      })),
    };
  }

  function tokenMatches(given, expected) {
    const a = Buffer.from(String(given));
    const b = Buffer.from(String(expected));
    // timingSafeEqual avoids leaking the token through response timing.
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  }

  // ---------------------------------------------------------------------------
  // Routes
  // ---------------------------------------------------------------------------
  const app = express();
  app.disable('x-powered-by'); // don't advertise the framework
  app.set('trust proxy', config.trustProxy); // which proxies may tell us the visitor's real IP
  app.use(express.json({ limit: '1kb' })); // tiny request bodies only

  // While we are deliberately crashing, refuse new work.
  app.use('/api', (req, res, next) => {
    res.set('Cache-Control', 'no-store');
    if (crashing) return res.status(503).json({ error: 'app_down', message: 'The server is crashing on purpose.' });
    next();
  });

  app.get('/api/health', (req, res) => {
    res.json({ status: 'ok', uptimeSec: Math.floor((now() - startedAt) / 1000), store: store.kind, bootId });
  });

  // Deep check. Cached for 5 s so it can't be used to hammer AWS.
  app.get('/api/status', async (req, res) => {
    if (statusCache.body && now() - statusCache.at < 5000) {
      return res.status(statusCache.body.status === 'ok' ? 200 : 503).json(statusCache.body);
    }
    const run = async (fn) => {
      try {
        return await fn();
      } catch (err) {
        return { ok: false, detail: `${err.name}: ${err.message}` };
      }
    };
    const database = await run(() => store.check());
    const storage = await run(() => backup.check());
    const body = {
      status: database.ok && storage.ok ? 'ok' : 'degraded',
      checks: { database, storage },
      region: config.region || '(local)',
      node: process.version,
      environment: config.nodeEnv,
      memoryMb: Math.round(process.memoryUsage().rss / 1024 / 1024),
      uptimeSec: Math.floor((now() - startedAt) / 1000),
    };
    statusCache = { at: now(), body };
    res.status(body.status === 'ok' ? 200 : 503).json(body);
  });

  app.get('/api/state', (req, res) => {
    touchPlayer(cleanPlayerId(req.query.pid), req.query.team);
    res.json(view());
  });

  app.post('/api/pull', (req, res) => {
    const { team, count = 1 } = req.body || {};
    const playerId = cleanPlayerId(req.body?.pid);

    if (!TEAMS.includes(team)) {
      return res.status(400).json({ error: 'bad_team', message: 'team must be "red" or "blue"' });
    }
    if (!Number.isInteger(count) || count < 1 || count > MAX_CLICKS_PER_REQUEST) {
      return res
        .status(400)
        .json({ error: 'bad_count', message: `count must be a whole number from 1 to ${MAX_CLICKS_PER_REQUEST}` });
    }
    // Two quotas: one per player (fair play) and one per IP address (flood protection).
    if (!perIp.take(req.ip, count) || !perPlayer.take(`${req.ip}|${playerId || 'anon'}`, count)) {
      return res.status(429).json({ error: 'too_fast', message: 'Slow down a little!' });
    }

    touchPlayer(playerId, team);
    const finished = game.pull(team, count);
    dirty = true;

    if (finished) {
      lastRound = finished;
      logger.info('round finished', finished);
      // Save in the background; the player gets an instant answer.
      store.addRound(finished).catch((err) => logger.error('saving round failed', { error: err.message }));
      saveIfDirty();
      backup.putJson('backups/state-latest.json', { savedAt: new Date(now()).toISOString(), state: game.snapshot() });
    }
    res.json(view());
  });

  app.post('/api/chaos', async (req, res) => {
    const remaining = game.chaosCooldownRemaining(config.chaosCooldownSec);
    if (remaining > 0) {
      return res.status(429).json({
        error: 'cooldown',
        retryAfterSec: remaining,
        message: `The server is still catching its breath. Try again in ${remaining}s.`,
      });
    }

    crashing = true;
    const crashedAt = now();
    const incident = {
      id: new Date(crashedAt).toISOString(),
      crashedAt,
      status: 'open',
      trigger: 'chaos-button',
      round: game.state.round,
      bootId,
    };

    const before = game.snapshot();
    try {
      // Write the evidence FIRST, so the next process can finish the story.
      game.markChaos();
      await store.putIncident(incident);
      await store.saveState(game.snapshot());
      dirty = false;
    } catch (err) {
      game.restore(before); // undo: no crash happened
      crashing = false;
      logger.error('could not record the crash, so not crashing', { error: err.message });
      return res.status(500).json({ error: 'store_failed', message: 'Could not record the crash, try again.' });
    }

    logger.warn('CHAOS button pressed: crashing on purpose', { incident: incident.id, round: incident.round });
    res.status(202).json({ status: 'crashing', incident: incident.id, message: 'Boom. Watch me heal.' });
    // Give the response a moment to reach the browser, then die.
    setTimeout(crash, 150);
  });

  app.post('/api/admin/reset', async (req, res) => {
    if (!config.adminToken) return res.status(404).json({ error: 'not_found' });
    const header = req.get('authorization') || '';
    const given = header.startsWith('Bearer ') ? header.slice(7) : '';
    if (!tokenMatches(given, config.adminToken)) {
      logger.warn('admin reset rejected: wrong token', { ip: req.ip });
      return res.status(401).json({ error: 'unauthorized' });
    }
    game.resetScores();
    lastRound = null;
    dirty = true;
    await saveIfDirty();
    logger.info('game reset by admin');
    res.json(view());
  });

  app.use('/api', (req, res) => res.status(404).json({ error: 'not_found' }));

  if (config.serveStatic) {
    app.use(express.static(path.join(__dirname, '..', 'public'), { extensions: ['html'] }));
  }

  // Last-resort error handler (e.g. broken JSON in a request body).
  // eslint-disable-next-line no-unused-vars
  app.use((err, req, res, next) => {
    const status = err.status && err.status < 500 ? err.status : 500;
    if (status === 500) logger.error('unexpected error', { error: err.message, path: req.path });
    res.status(status).json({ error: status === 500 ? 'server_error' : 'bad_request' });
  });

  return { app, init, stop, view };
}

module.exports = { createArena };
