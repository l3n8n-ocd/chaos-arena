'use strict';
// =============================================================================
// dev-heal.js — a tiny stand-in for systemd, for local development only.
//
// It runs server.js and, whenever the server exits with an error (for example
// after someone presses CHAOS), starts it again after 2 seconds. This lets you
// try the full crash -> heal -> recover loop on your own computer:
//
//     npm run dev:heal        then open http://localhost:3000
//
// On the real server this job is done by systemd (Restart=always).
// =============================================================================
const { spawn } = require('node:child_process');
const path = require('node:path');

const RESTART_DELAY_MS = 2000;
let child = null;
let stopping = false;

function start() {
  child = spawn(process.execPath, [path.join(__dirname, '..', 'server.js')], { stdio: 'inherit' });
  child.on('exit', (code, signal) => {
    if (stopping) return process.exit(0);
    console.log(`[dev-heal] server exited (code=${code}, signal=${signal}). Restarting in ${RESTART_DELAY_MS / 1000}s...`);
    setTimeout(start, RESTART_DELAY_MS);
  });
}

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    stopping = true;
    if (child) child.kill(signal);
    else process.exit(0);
  });
}

start();
