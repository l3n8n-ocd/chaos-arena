'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { MemoryStore } = require('../src/store-memory');
const { startArena, sleep } = require('../support/harness');

const PID = 'player-abc123';

test('health and deep status report ok', async () => {
  const t = await startArena();
  try {
    const health = await t.get('/api/health');
    assert.equal(health.status, 200);
    assert.equal(health.data.status, 'ok');
    assert.equal(health.headers.get('x-powered-by'), null);

    const status = await t.get('/api/status');
    assert.equal(status.status, 200);
    assert.equal(status.data.checks.database.ok, true);
    assert.equal(status.data.checks.storage.ok, true);
  } finally { await t.close(); }
});

test('deep status is 503 when the database is unreachable', async () => {
  const store = new MemoryStore();
  store.check = async () => { throw new Error('table not found'); };
  const t = await startArena({ store });
  try {
    const status = await t.get('/api/status');
    assert.equal(status.status, 503);
    assert.equal(status.data.status, 'degraded');
    assert.match(status.data.checks.database.detail, /table not found/);
  } finally { await t.close(); }
});

test('pulling moves the rope and counts players', async () => {
  const t = await startArena();
  try {
    const res = await t.post('/api/pull', { team: 'red', count: 3, pid: PID });
    assert.equal(res.status, 200);
    assert.equal(res.data.rope, -3);
    assert.deepEqual(res.data.players, { total: 1, red: 1, blue: 0 });

    const state = await t.get(`/api/state?pid=other-player-1&team=blue`);
    assert.equal(state.data.rope, -3);
    assert.deepEqual(state.data.players, { total: 2, red: 1, blue: 1 });
    assert.equal(state.headers.get('cache-control'), 'no-store');
  } finally { await t.close(); }
});

test('bad requests are rejected', async () => {
  const t = await startArena();
  try {
    assert.equal((await t.post('/api/pull', { team: 'green', count: 1 })).status, 400);
    assert.equal((await t.post('/api/pull', { team: 'red', count: 9 })).status, 400);
    assert.equal((await t.post('/api/pull', { team: 'red', count: 1.5 })).status, 400);
    assert.equal((await t.post('/api/pull', { team: 'red', count: -1 })).status, 400);
    assert.equal((await t.get('/api/nope')).status, 404);
    // Broken JSON must give a 400, not crash the server.
    const res = await fetch(t.base + '/api/pull', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{oops' });
    assert.equal(res.status, 400);
    // Oversized bodies are refused.
    const big = await fetch(t.base + '/api/pull', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ team: 'red', junk: 'x'.repeat(5000) }) });
    assert.equal(big.status, 413);
  } finally { await t.close(); }
});

test('winning a round is recorded and backed up', async () => {
  const t = await startArena(); // WIN_AT = 5
  try {
    const res = await t.post('/api/pull', { team: 'blue', count: 5, pid: PID });
    assert.equal(res.data.round, 2);
    assert.equal(res.data.rope, 0);
    assert.deepEqual(res.data.wins, { red: 0, blue: 1 });
    assert.equal(res.data.lastRound.winner, 'blue');
    await sleep(20);
    const rounds = await t.store.listRounds();
    assert.equal(rounds.length, 1);
    assert.equal(rounds[0].winner, 'blue');
    assert.equal(t.backups[0].key, 'backups/state-latest.json');
    assert.equal((await t.store.loadState()).wins.blue, 1);
  } finally { await t.close(); }
});

test('clicking too fast hits the rate limit', async () => {
  const t = await startArena({ env: { WIN_AT: '1000' } });
  try {
    let limited = 0;
    for (let i = 0; i < 6; i += 1) {
      const res = await t.post('/api/pull', { team: 'red', count: 8, pid: PID });
      if (res.status === 429) limited += 1;
    }
    assert.equal(limited, 2); // burst of 32 clicks = 4 requests of 8, then blocked
    t.clock.t += 2000; // two seconds later the bucket has refilled
    assert.equal((await t.post('/api/pull', { team: 'red', count: 8, pid: PID })).status, 200);
  } finally { await t.close(); }
});

test('CHAOS records an incident, crashes, and the next start measures recovery', async () => {
  const store = new MemoryStore();
  const first = await startArena({ store });
  await first.post('/api/pull', { team: 'red', count: 4, pid: PID });

  const chaos = await first.post('/api/chaos', { pid: PID });
  assert.equal(chaos.status, 202);
  // While crashing, new requests are refused...
  assert.equal((await first.get('/api/state')).status, 503);
  await sleep(250);
  // ...and then the process "dies" (in tests the crash function just records it).
  assert.equal(first.crashes.length, 1);

  const open = await store.listIncidents();
  assert.equal(open.length, 1);
  assert.equal(open[0].status, 'open');
  await first.close();

  // --- systemd restarts the app 3.2 seconds later (same database) ---
  const second = await startArena({ store });
  second.clock.t = first.clock.t; // same wall clock...
  try {
    const healed = await store.listIncidents();
    assert.equal(healed[0].status, 'recovered');
    const state = await second.get('/api/state');
    assert.equal(state.data.rope, -4, 'the game continues where it stopped');
    assert.equal(state.data.chaos.total, 1);
    assert.equal(state.data.incidents[0].status, 'recovered');
    assert.equal(state.data.chaos.lastRecoveryMs, healed[0].recoveryMs);
    assert.equal(second.backups[0].key.startsWith('incidents/'), true);

    // Cooldown: a second press right away is refused.
    const again = await second.post('/api/chaos', { pid: PID });
    assert.equal(again.status, 429);
    assert.equal(again.data.error, 'cooldown');
    assert.equal(second.crashes.length, 0);

    // After the cooldown it works again.
    second.clock.t += 61000;
    assert.equal((await second.post('/api/chaos', { pid: PID })).status, 202);
  } finally { await second.close(); }
});

test('recovery time is measured from the crash to the restart', async () => {
  const store = new MemoryStore();
  const crashedAt = 1_800_000_000_000 - 3200; // helper clock starts at 1_800_000_000_000
  await store.putIncident({ id: new Date(crashedAt).toISOString(), crashedAt, status: 'open', round: 1 });
  const t = await startArena({ store });
  try {
    const state = await t.get('/api/state');
    assert.equal(state.data.chaos.lastRecoveryMs, 3200);
    assert.equal(state.data.chaos.avgRecoveryMs, 3200);
  } finally { await t.close(); }
});

test('if the crash cannot be recorded, the server does not crash', async () => {
  const store = new MemoryStore();
  store.putIncident = async () => { throw new Error('database offline'); };
  const t = await startArena({ store });
  try {
    const res = await t.post('/api/chaos', { pid: PID });
    assert.equal(res.status, 500);
    await sleep(250);
    assert.equal(t.crashes.length, 0);
    const state = await t.get('/api/state');
    assert.equal(state.status, 200);
    assert.equal(state.data.chaos.total, 0);
  } finally { await t.close(); }
});

test('admin reset needs the secret token', async () => {
  const t = await startArena();
  try {
    await t.post('/api/pull', { team: 'blue', count: 5, pid: PID });
    assert.equal((await t.post('/api/admin/reset', {})).status, 401);
    assert.equal((await t.post('/api/admin/reset', {}, { Authorization: 'Bearer wrong-token-000000000' })).status, 401);
    const ok = await t.post('/api/admin/reset', {}, { Authorization: 'Bearer test-token-1234567890' });
    assert.equal(ok.status, 200);
    assert.deepEqual(ok.data.wins, { red: 0, blue: 0 });
  } finally { await t.close(); }
});

test('admin reset is hidden when no token is configured', async () => {
  const t = await startArena({ env: { ADMIN_TOKEN: '' } });
  try {
    assert.equal((await t.post('/api/admin/reset', {}, { Authorization: 'Bearer ' })).status, 404);
  } finally { await t.close(); }
});

test('the web page is served in development', async () => {
  const t = await startArena();
  try {
    const res = await fetch(t.base + '/');
    assert.equal(res.status, 200);
    assert.match(await res.text(), /<title>Chaos Arena<\/title>/);
  } finally { await t.close(); }
});

test('behind trusted proxies, each visitor gets their own rate limit', async () => {
  // Simulates Docker: host Nginx -> web container (private IP) -> app.
  const t = await startArena({ env: { WIN_AT: '1000', TRUST_PROXY: 'loopback, uniquelocal' } });
  try {
    const via = (client) => ({ 'X-Forwarded-For': `${client}, 172.18.0.1` });
    for (let i = 0; i < 4; i += 1) {
      assert.equal((await t.post('/api/pull', { team: 'red', count: 8, pid: PID }, via('203.0.113.10'))).status, 200);
    }
    assert.equal((await t.post('/api/pull', { team: 'red', count: 8, pid: PID }, via('203.0.113.10'))).status, 429);
    // A different visitor (same player id, different real IP) is not blocked.
    assert.equal((await t.post('/api/pull', { team: 'red', count: 8, pid: PID }, via('198.51.100.7'))).status, 200);
  } finally { await t.close(); }
});
