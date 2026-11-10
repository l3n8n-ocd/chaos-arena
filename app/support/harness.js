'use strict';
// Shared test helpers: start a real HTTP server with an in-memory store and a
// controllable clock, so tests are fast and never touch AWS.
const { loadConfig } = require('../src/config');
const { createLogger } = require('../src/logger');
const { Game } = require('../src/game');
const { MemoryStore } = require('../src/store-memory');
const { createArena } = require('../src/app');

async function startArena({ env = {}, store = new MemoryStore(), backup } = {}) {
  const clock = { t: 1_800_000_000_000 };
  const now = () => clock.t;
  const config = loadConfig({
    STORE: 'memory',
    WIN_AT: '5',
    CHAOS_COOLDOWN_SEC: '60',
    ADMIN_TOKEN: 'test-token-1234567890',
    SERVE_STATIC: 'true',
    ...env,
  });
  const saved = [];
  const fakeBackup = backup || {
    enabled: true,
    async putJson(key, value) { saved.push({ key, value }); },
    async check() { return { ok: true, kind: 'fake', detail: 'fake bucket' }; },
  };
  const crashes = [];
  const arena = createArena({
    config,
    game: new Game({ winAt: config.winAt, now }),
    store,
    backup: fakeBackup,
    logger: createLogger({ silent: true }),
    crash: () => crashes.push(now()),
    now,
  });
  await arena.init();
  const server = await new Promise((resolve) => {
    const s = arena.app.listen(0, '127.0.0.1', () => resolve(s));
  });
  const base = `http://127.0.0.1:${server.address().port}`;

  async function request(method, path, body, headers = {}) {
    const res = await fetch(base + path, {
      method,
      headers: body ? { 'Content-Type': 'application/json', ...headers } : headers,
      body: body ? JSON.stringify(body) : undefined,
    });
    let data = null;
    try { data = await res.json(); } catch { /* not JSON */ }
    return { status: res.status, data, headers: res.headers };
  }

  return {
    arena, store, clock, crashes, backups: saved, base,
    get: (path, headers) => request('GET', path, null, headers),
    post: (path, body, headers) => request('POST', path, body, headers),
    async close() {
      await arena.stop();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

module.exports = { startArena, sleep };
