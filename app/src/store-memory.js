'use strict';
// =============================================================================
// store-memory.js — keeps game data in memory, optionally mirrored to a JSON file.
//
//   STORE=memory -> nothing is saved (used by the automated tests)
//   STORE=file   -> saved to app/.data/store.json (used on my laptop, so the
//                   game survives a restart without needing AWS)
//
// It has exactly the same methods as store-dynamo.js, so the rest of the app
// doesn't care which one it is talking to.
// =============================================================================

const fs = require('node:fs');
const path = require('node:path');

class MemoryStore {
  constructor({ file = null } = {}) {
    this.kind = file ? 'file' : 'memory';
    this.file = file;
    this.data = { state: null, incidents: [], rounds: [] };
    if (file && fs.existsSync(file)) {
      try {
        this.data = { ...this.data, ...JSON.parse(fs.readFileSync(file, 'utf8')) };
      } catch {
        // A broken file must never stop the game from starting: begin fresh.
      }
    }
  }

  _persist() {
    if (!this.file) return;
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    fs.writeFileSync(this.file, JSON.stringify(this.data, null, 2));
  }

  async loadState() {
    return this.data.state;
  }

  async saveState(state) {
    this.data.state = state;
    this._persist();
  }

  /** Create or update one incident (a crash + its recovery). */
  async putIncident(incident) {
    const others = this.data.incidents.filter((i) => i.id !== incident.id);
    this.data.incidents = [...others, { ...incident }].sort((a, b) => (a.id < b.id ? 1 : -1));
    this._persist();
  }

  /** Newest first. */
  async listIncidents(limit = 20) {
    return this.data.incidents.slice(0, limit).map((i) => ({ ...i }));
  }

  async addRound(round) {
    this.data.rounds = [{ ...round }, ...this.data.rounds].slice(0, 200);
    this._persist();
  }

  /** Newest first. */
  async listRounds(limit = 5) {
    return this.data.rounds.slice(0, limit).map((r) => ({ ...r }));
  }

  /** Health check: is the database reachable? */
  async check() {
    return { ok: true, kind: this.kind, detail: this.file ? `file ${this.file}` : 'in memory only' };
  }
}

module.exports = { MemoryStore };
