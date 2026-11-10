'use strict';
// =============================================================================
// game.js — the browser side of Chaos Arena.
//
// The page asks the server for the game state about once a second ("polling")
// and sends clicks in small batches. If the server stops answering, the page
// notices, shows a "self-healing" timer, and reconnects by itself.
// =============================================================================
(() => {
  const POLL_MS = 1000; // normal refresh rate
  const POLL_DOWN_MS = 400; // refresh faster while the server is down, for an accurate timer
  const FLUSH_MS = 200; // how often queued clicks are sent
  const MAX_BATCH = 8; // must match MAX_CLICKS_PER_REQUEST on the server
  const TIMEOUT_MS = 2500;

  const $ = (id) => document.getElementById(id);
  const el = {
    status: $('status'), statusText: $('status-text'),
    winsRed: $('wins-red'), winsBlue: $('wins-blue'), round: $('round'),
    arena: $('arena'), rope: $('rope'), flag: $('flag'), banner: $('banner'), ropeText: $('rope-text'),
    joinRed: $('join-red'), joinBlue: $('join-blue'), pull: $('pull'), players: $('players'),
    chaos: $('chaos'),
    uptime: $('stat-uptime'), crashes: $('stat-crashes'), last: $('stat-last'), avg: $('stat-avg'),
    incidents: $('incidents'),
  };

  // ---- small helpers --------------------------------------------------------
  function storageGet(key) { try { return localStorage.getItem(key); } catch { return null; } }
  function storageSet(key, value) { try { localStorage.setItem(key, value); } catch { /* private mode */ } }

  function randomId() {
    const bytes = new Uint8Array(12);
    crypto.getRandomValues(bytes);
    return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
  }

  function formatMs(ms) {
    if (ms === null || ms === undefined) return '–';
    return ms < 10000 ? `${(ms / 1000).toFixed(1)} s` : `${Math.round(ms / 1000)} s`;
  }

  function formatUptime(sec) {
    if (sec < 60) return `${sec}s`;
    if (sec < 3600) return `${Math.floor(sec / 60)}m ${sec % 60}s`;
    if (sec < 86400) return `${Math.floor(sec / 3600)}h ${Math.floor((sec % 3600) / 60)}m`;
    return `${Math.floor(sec / 86400)}d ${Math.floor((sec % 86400) / 3600)}h`;
  }

  function timeAgo(ms) {
    const sec = Math.max(0, Math.round((Date.now() - ms) / 1000));
    if (sec < 60) return 'just now';
    if (sec < 3600) return `${Math.floor(sec / 60)} min ago`;
    if (sec < 86400) return `${Math.floor(sec / 3600)} h ago`;
    return new Date(ms).toLocaleDateString();
  }

  async function api(path, options = {}) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
    try {
      const res = await fetch(path, {
        cache: 'no-store',
        signal: controller.signal,
        headers: options.body ? { 'Content-Type': 'application/json' } : undefined,
        ...options,
        body: options.body ? JSON.stringify(options.body) : undefined,
      });
      let data = null;
      try { data = await res.json(); } catch { /* not JSON */ }
      return { ok: res.ok, status: res.status, data };
    } finally {
      clearTimeout(timer);
    }
  }

  // ---- state ----------------------------------------------------------------
  let pid = storageGet('arena-pid');
  if (!pid) { pid = randomId(); storageSet('arena-pid', pid); }
  let team = ['red', 'blue'].includes(storageGet('arena-team')) ? storageGet('arena-team') : null;

  let state = null; // last state received from the server
  let stateAt = 0; // when we received it (for the live uptime counter)
  let pending = 0; // clicks not yet sent
  let sending = false;
  let down = false;
  let downSince = 0;
  let everConnected = false;
  let bannerTimer = null;
  let chaosArmedTimer = null;
  let cooldownUntil = 0;
  let lastRoundSeen = null;

  // ---- drawing --------------------------------------------------------------
  function showBanner(text, kind, autoHideMs) {
    clearTimeout(bannerTimer);
    el.banner.textContent = text;
    el.banner.className = `banner ${kind}`;
    el.banner.hidden = false;
    if (autoHideMs) bannerTimer = setTimeout(() => { el.banner.hidden = true; }, autoHideMs);
  }

  function setStatus(kind, text) {
    el.status.className = `status ${kind}`;
    el.statusText.textContent = text;
  }

  function renderTeam() {
    el.joinRed.setAttribute('aria-pressed', String(team === 'red'));
    el.joinBlue.setAttribute('aria-pressed', String(team === 'blue'));
    el.pull.className = `pull ${team || ''}`;
    el.pull.textContent = team ? `PULL FOR ${team.toUpperCase()}` : 'Pick a team to play';
    el.pull.disabled = !team || down || !state;
  }

  function renderChaos() {
    const remaining = Math.max(0, Math.ceil((cooldownUntil - Date.now()) / 1000));
    const armed = el.chaos.classList.contains('armed');
    el.chaos.disabled = down || !state || remaining > 0;
    if (down) el.chaos.textContent = 'HEALING…';
    else if (remaining > 0) el.chaos.textContent = `READY IN ${remaining}s`;
    else if (!armed) el.chaos.textContent = 'CHAOS';
  }

  function render() {
    if (!state) return;
    const s = state;
    // Show our own unsent clicks immediately, so the game feels instant.
    const direction = team === 'blue' ? 1 : -1;
    const rope = Math.max(-s.winAt, Math.min(s.winAt, s.rope + pending * direction));
    const pos = 50 + (rope / s.winAt) * 45; // 5% (red wins) ... 95% (blue wins)
    el.arena.style.setProperty('--pos', `${pos}%`);

    el.winsRed.textContent = s.wins.red;
    el.winsBlue.textContent = s.wins.blue;
    el.round.textContent = s.round;

    if (rope === 0) el.ropeText.textContent = 'The rope is dead centre.';
    else {
      const leader = rope < 0 ? 'Red' : 'Blue';
      el.ropeText.textContent = `${leader} is ahead: ${s.winAt - Math.abs(rope)} more to win the round.`;
    }

    const p = s.players;
    el.players.textContent = `${p.total} player${p.total === 1 ? '' : 's'} (${p.red} red, ${p.blue} blue)`;

    el.crashes.textContent = s.chaos.total;
    el.last.textContent = formatMs(s.chaos.lastRecoveryMs);
    el.avg.textContent = formatMs(s.chaos.avgRecoveryMs);

    el.incidents.replaceChildren(
      ...(s.incidents.length
        ? s.incidents.map((i) => {
            const li = document.createElement('li');
            const time = document.createElement('span');
            time.className = 'time';
            time.textContent = `Crashed ${timeAgo(i.crashedAt)}`;
            const rec = document.createElement('span');
            rec.className = i.status === 'recovered' ? 'rec' : 'rec open';
            rec.textContent = i.status === 'recovered' ? `healed in ${formatMs(i.recoveryMs)}` : 'healing…';
            li.append(time, rec);
            return li;
          })
        : [Object.assign(document.createElement('li'), { className: 'muted', textContent: 'Nobody has pressed the button yet.' })])
    );

    renderTeam();
    renderChaos();
  }

  function renderClock() {
    if (down) {
      const sec = ((Date.now() - downSince) / 1000).toFixed(1);
      showBanner(`💥 Server crashed. Self-healing… ${sec}s`, 'down');
      el.uptime.textContent = '0s';
    } else if (state) {
      el.uptime.textContent = formatUptime(state.server.uptimeSec + Math.floor((Date.now() - stateAt) / 1000));
    }
    renderChaos();
  }

  // ---- talking to the server ------------------------------------------------
  function receive(data) {
    state = data;
    stateAt = Date.now();
    cooldownUntil = Date.now() + data.chaos.cooldownRemainingSec * 1000;

    // Announce the winner when a round ends.
    const lr = data.lastRound;
    if (lr && lastRoundSeen !== null && lr.round !== lastRoundSeen && !down) {
      const name = lr.winner === 'red' ? 'Red' : 'Blue';
      showBanner(`🏆 ${name} wins round ${lr.round}!`, `win-${lr.winner}`, 2500);
    }
    lastRoundSeen = lr ? lr.round : 0;
  }

  function markDown() {
    if (down) return;
    down = true;
    downSince = Date.now();
    pending = 0;
    el.arena.classList.add('down');
    setStatus('down', everConnected ? 'Server down, healing…' : 'Server unreachable, retrying…');
    render();
    renderClock();
  }

  function markUp() {
    const wasDown = down && everConnected; // a failed FIRST connection is not a "crash"
    const observedMs = Date.now() - downSince;
    down = false;
    everConnected = true;
    el.arena.classList.remove('down');
    el.banner.hidden = true;
    setStatus('online', 'Server online');
    if (wasDown) {
      // Prefer the server's own measurement if this outage was a recorded crash.
      const latest = state.incidents[0];
      const recorded = latest && latest.status === 'recovered' && latest.crashedAt > downSince - 5000;
      const ms = recorded ? latest.recoveryMs : observedMs;
      showBanner(`✅ Healed itself in ${formatMs(ms)}. Game on!`, 'recovered', 3500);
    }
  }

  async function poll() {
    try {
      const params = new URLSearchParams({ pid });
      if (team) params.set('team', team);
      const res = await api(`/api/state?${params}`);
      if (res.ok && res.data) {
        receive(res.data);
        if (down || !everConnected) markUp();
        render();
      } else if (res.status >= 500) {
        markDown();
      }
    } catch {
      markDown(); // network error or timeout
    }
    setTimeout(poll, down ? POLL_DOWN_MS : POLL_MS);
  }

  async function flush() {
    if (sending || down || pending === 0 || !team) return;
    const count = Math.min(pending, MAX_BATCH);
    sending = true;
    try {
      const res = await api('/api/pull', { method: 'POST', body: { team, count, pid } });
      pending = Math.max(0, pending - count);
      if (res.ok && res.data) receive(res.data);
      else if (res.status === 429) pending = 0; // clicking too fast: drop the queue
      else if (res.status >= 500) markDown();
    } catch {
      markDown();
    } finally {
      sending = false;
      render();
    }
  }

  function pull() {
    if (!team || down || !state) return;
    if (pending < MAX_BATCH * 3) pending += 1; // don't queue more than we could ever send
    render();
  }

  // ---- buttons --------------------------------------------------------------
  function join(newTeam) {
    team = newTeam;
    pending = 0;
    storageSet('arena-team', team);
    render();
    renderTeam();
  }
  el.joinRed.addEventListener('click', () => join('red'));
  el.joinBlue.addEventListener('click', () => join('blue'));
  el.pull.addEventListener('click', pull);

  document.addEventListener('keydown', (event) => {
    if (event.code !== 'Space') return;
    if (event.target instanceof HTMLButtonElement && event.target !== el.pull) return;
    event.preventDefault();
    pull(); // holding Space repeats automatically
  });

  function disarmChaos() {
    clearTimeout(chaosArmedTimer);
    el.chaos.classList.remove('armed');
    renderChaos();
  }

  el.chaos.addEventListener('click', async () => {
    if (!el.chaos.classList.contains('armed')) {
      // First click only arms the button; a second click within 3 s confirms.
      el.chaos.classList.add('armed');
      el.chaos.textContent = 'SURE? CLICK AGAIN';
      chaosArmedTimer = setTimeout(disarmChaos, 3000);
      return;
    }
    disarmChaos();
    try {
      const res = await api('/api/chaos', { method: 'POST', body: { pid } });
      if (res.status === 202) {
        markDown(); // we know what is about to happen
      } else if (res.status === 429 && res.data) {
        cooldownUntil = Date.now() + res.data.retryAfterSec * 1000;
        renderChaos();
      } else if (res.status >= 500) {
        markDown();
      }
    } catch {
      markDown();
    }
  });

  // ---- go -------------------------------------------------------------------
  renderTeam();
  poll();
  setInterval(flush, FLUSH_MS);
  setInterval(renderClock, 100);
})();
