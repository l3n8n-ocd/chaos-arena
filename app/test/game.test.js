'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { Game } = require('../src/game');

test('red pulls left, blue pulls right', () => {
  const game = new Game({ winAt: 10 });
  game.pull('red', 3);
  assert.equal(game.state.rope, -3);
  game.pull('blue', 5);
  assert.equal(game.state.rope, 2);
  assert.deepEqual(game.state.clicks, { red: 3, blue: 5 });
  assert.equal(game.state.totalClicks, 8);
});

test('reaching the end wins the round and resets the rope', () => {
  let t = 1000;
  const game = new Game({ winAt: 5, now: () => t });
  game.pull('blue', 4);
  t = 6000;
  const finished = game.pull('blue', 1);
  assert.equal(finished.winner, 'blue');
  assert.equal(finished.round, 1);
  assert.equal(finished.durationMs, 5000);
  assert.equal(game.state.rope, 0);
  assert.equal(game.state.round, 2);
  assert.deepEqual(game.state.wins, { red: 0, blue: 1 });
  assert.deepEqual(game.state.clicks, { red: 0, blue: 0 });
});

test('unknown teams are rejected', () => {
  const game = new Game();
  assert.throws(() => game.pull('green'), /Unknown team/);
});

test('snapshot + restore brings the game back after a restart', () => {
  const before = new Game({ winAt: 10 });
  before.pull('red', 7);
  before.markChaos();
  const after = new Game({ winAt: 10 });
  after.restore(before.snapshot());
  assert.equal(after.state.rope, -7);
  assert.equal(after.state.chaosCount, 1);
  assert.deepEqual(after.state, before.state);
});

test('restore survives broken or missing data', () => {
  const game = new Game({ winAt: 10 });
  game.restore(null);
  game.restore({ rope: 'banana', wins: null, round: -4 });
  assert.equal(game.state.rope, 0);
  assert.equal(game.state.round, 1);
  assert.deepEqual(game.state.wins, { red: 0, blue: 0 });
  // A saved rope beyond the win line (e.g. WIN_AT was lowered) is pulled back inside.
  game.restore({ rope: 99 });
  assert.equal(game.state.rope, 9);
});

test('chaos cooldown counts down', () => {
  let t = 100000;
  const game = new Game({ now: () => t });
  assert.equal(game.chaosCooldownRemaining(60), 0);
  game.markChaos();
  assert.equal(game.chaosCooldownRemaining(60), 60);
  t += 45500;
  assert.equal(game.chaosCooldownRemaining(60), 15);
  t += 20000;
  assert.equal(game.chaosCooldownRemaining(60), 0);
});

test('admin reset clears scores but keeps crash history', () => {
  const game = new Game({ winAt: 3 });
  game.pull('red', 3);
  game.markChaos();
  game.resetScores();
  assert.deepEqual(game.state.wins, { red: 0, blue: 0 });
  assert.equal(game.state.round, 1);
  assert.equal(game.state.chaosCount, 1);
});
