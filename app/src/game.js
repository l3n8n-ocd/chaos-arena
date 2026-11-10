'use strict';
// =============================================================================
// game.js — the tug-of-war rules. Pure logic: no network, no database.
//
// The rope position is a number:
//      -winAt ......... 0 ......... +winAt
//      RED wins       centre       BLUE wins
// Every red click moves the rope -1, every blue click moves it +1.
// =============================================================================

const TEAMS = ['red', 'blue'];

function freshState(now) {
  return {
    rope: 0,
    round: 1,
    wins: { red: 0, blue: 0 },
    clicks: { red: 0, blue: 0 }, // clicks in the current round
    totalClicks: 0,
    roundStartedAt: now,
    lastChaosAt: 0, // when the CHAOS button was last pressed (ms)
    chaosCount: 0, // how many times the server has been crashed on purpose
  };
}

class Game {
  constructor({ winAt = 50, now = Date.now } = {}) {
    this.winAt = winAt;
    this.now = now;
    this.state = freshState(now());
  }

  /** A plain copy of the state, safe to save to the database. */
  snapshot() {
    return JSON.parse(JSON.stringify(this.state));
  }

  /** Load a state that was saved earlier (after a restart or crash). */
  restore(saved) {
    if (!saved || typeof saved !== 'object') return;
    const base = freshState(this.now());
    const num = (v, fallback) => (Number.isFinite(v) ? v : fallback);
    this.state = {
      rope: Math.max(-this.winAt + 1, Math.min(this.winAt - 1, num(saved.rope, 0))),
      round: Math.max(1, num(saved.round, 1)),
      wins: { red: num(saved.wins?.red, 0), blue: num(saved.wins?.blue, 0) },
      clicks: { red: num(saved.clicks?.red, 0), blue: num(saved.clicks?.blue, 0) },
      totalClicks: num(saved.totalClicks, 0),
      roundStartedAt: num(saved.roundStartedAt, base.roundStartedAt),
      lastChaosAt: num(saved.lastChaosAt, 0),
      chaosCount: num(saved.chaosCount, 0),
    };
  }

  /**
   * A team pulls the rope `count` times.
   * Returns null normally, or a summary of the round if this pull won it.
   */
  pull(team, count = 1) {
    if (!TEAMS.includes(team)) throw new Error(`Unknown team: ${team}`);
    const s = this.state;
    const direction = team === 'blue' ? 1 : -1;

    s.rope += direction * count;
    s.clicks[team] += count;
    s.totalClicks += count;

    if (Math.abs(s.rope) < this.winAt) return null;

    // Somebody won the round.
    const finishedAt = this.now();
    const finished = {
      round: s.round,
      winner: team,
      clicks: { ...s.clicks },
      durationMs: finishedAt - s.roundStartedAt,
      finishedAt,
    };
    s.wins[team] += 1;
    s.round += 1;
    s.rope = 0;
    s.clicks = { red: 0, blue: 0 };
    s.roundStartedAt = finishedAt;
    return finished;
  }

  /** Seconds left before CHAOS can be pressed again. */
  chaosCooldownRemaining(cooldownSec) {
    const elapsedMs = this.now() - this.state.lastChaosAt;
    return Math.max(0, Math.ceil(cooldownSec - elapsedMs / 1000));
  }

  /** Remember that CHAOS was pressed (saved BEFORE the crash). */
  markChaos() {
    this.state.lastChaosAt = this.now();
    this.state.chaosCount += 1;
  }

  /** Admin reset: scores back to zero, but keep the crash history. */
  resetScores() {
    const { lastChaosAt, chaosCount } = this.state;
    this.state = { ...freshState(this.now()), lastChaosAt, chaosCount };
  }
}

module.exports = { Game, TEAMS };
