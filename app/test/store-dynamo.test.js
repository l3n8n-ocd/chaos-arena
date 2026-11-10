'use strict';
// Tests the DynamoDB store against a small fake client that behaves like a
// DynamoDB table (items identified by pk + sk, Query sorted by sk).
// This checks that our commands are shaped correctly without needing AWS.
const test = require('node:test');
const assert = require('node:assert/strict');
const { marshall, unmarshall } = require('@aws-sdk/util-dynamodb');
const { DynamoStore } = require('../src/store-dynamo');
const { startArena } = require('../support/harness');

function fakeDynamo() {
  const items = new Map(); // "pk|sk" -> item
  const calls = [];
  const doc = {
    async send(command) {
      const name = command.constructor.name;
      const input = command.input;
      calls.push({ name, input });
      assert.equal(input.TableName, 'test-table');
      if (name === 'PutCommand') {
        // marshall() throws on anything DynamoDB cannot store (e.g. undefined).
        const stored = unmarshall(marshall(input.Item, { removeUndefinedValues: true }));
        assert.equal(typeof stored.pk, 'string');
        assert.equal(typeof stored.sk, 'string');
        items.set(`${stored.pk}|${stored.sk}`, stored);
        return {};
      }
      if (name === 'GetCommand') {
        return { Item: items.get(`${input.Key.pk}|${input.Key.sk}`) };
      }
      if (name === 'QueryCommand') {
        assert.equal(input.KeyConditionExpression, '#pk = :pk');
        assert.equal(input.ExpressionAttributeNames['#pk'], 'pk');
        const pk = input.ExpressionAttributeValues[':pk'];
        let found = [...items.values()].filter((i) => i.pk === pk).sort((a, b) => (a.sk < b.sk ? -1 : 1));
        if (input.ScanIndexForward === false) found.reverse();
        return { Items: found.slice(0, input.Limit) };
      }
      throw new Error(`fake dynamo: unsupported command ${name}`);
    },
  };
  const raw = {
    async send(command) {
      assert.equal(command.constructor.name, 'DescribeTableCommand');
      return { Table: { TableStatus: 'ACTIVE' } };
    },
  };
  return { doc, raw, items, calls };
}

function makeStore() {
  const fake = fakeDynamo();
  const store = new DynamoStore({ region: 'ap-southeast-1', tableName: 'test-table', rawClient: fake.raw, docClient: fake.doc });
  return { store, fake };
}

test('state round-trips through the table', async () => {
  const { store, fake } = makeStore();
  assert.equal(await store.loadState(), null);
  const state = { rope: -7, round: 3, wins: { red: 2, blue: 0 }, clicks: { red: 9, blue: 2 }, totalClicks: 140, roundStartedAt: 1, lastChaosAt: 0, chaosCount: 0 };
  await store.saveState(state);
  assert.deepEqual(await store.loadState(), state);
  assert.equal(fake.items.has('STATE|CURRENT'), true);
});

test('incidents are listed newest first and can be updated', async () => {
  const { store } = makeStore();
  await store.putIncident({ id: '2026-11-10T08:00:00.000Z', crashedAt: 1, status: 'recovered', recoveryMs: 3000 });
  await store.putIncident({ id: '2026-11-10T09:00:00.000Z', crashedAt: 2, status: 'open' });
  let list = await store.listIncidents(20);
  assert.deepEqual(list.map((i) => i.id), ['2026-11-10T09:00:00.000Z', '2026-11-10T08:00:00.000Z']);
  assert.equal('pk' in list[0], false, 'internal keys are hidden');

  await store.putIncident({ ...list[0], status: 'recovered', recoveryMs: 2800, recoveredAt: 3 });
  list = await store.listIncidents(1);
  assert.equal(list.length, 1);
  assert.equal(list[0].status, 'recovered');
  assert.equal(list[0].recoveryMs, 2800);
});

test('rounds are stored by finish time', async () => {
  const { store, fake } = makeStore();
  await store.addRound({ round: 1, winner: 'red', clicks: { red: 5, blue: 0 }, durationMs: 1000, finishedAt: Date.parse('2026-11-10T08:00:00Z') });
  await store.addRound({ round: 2, winner: 'blue', clicks: { red: 1, blue: 6 }, durationMs: 900, finishedAt: Date.parse('2026-11-10T08:01:00Z') });
  assert.equal(fake.items.has('ROUND|2026-11-10T08:00:00.000Z'), true);
  const rounds = await store.listRounds(1);
  assert.equal(rounds[0].round, 2);
});

test('health check reports the table status', async () => {
  const { store } = makeStore();
  assert.deepEqual(await store.check(), { ok: true, kind: 'dynamo', detail: 'table test-table is ACTIVE' });
});

test('the whole game works on top of the DynamoDB store', async () => {
  const { store } = makeStore();
  const first = await startArena({ store });
  await first.post('/api/pull', { team: 'blue', count: 5, pid: 'player-abc123' }); // wins round 1 (WIN_AT=5)
  await first.post('/api/pull', { team: 'red', count: 2, pid: 'player-abc123' });
  assert.equal((await first.post('/api/chaos', {})).status, 202);
  await first.close();

  const second = await startArena({ store });
  try {
    const state = (await second.get('/api/state')).data;
    assert.equal(state.rope, -2);
    assert.equal(state.round, 2);
    assert.deepEqual(state.wins, { red: 0, blue: 1 });
    assert.equal(state.lastRound.winner, 'blue');
    assert.equal(state.chaos.total, 1);
    assert.equal(state.incidents[0].status, 'recovered');
    assert.equal((await second.get('/api/status')).data.checks.database.detail, 'table test-table is ACTIVE');
  } finally { await second.close(); }
});
