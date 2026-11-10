'use strict';
// =============================================================================
// logger.js — structured logging.
//
// Every log line is ONE line of JSON, for example:
//   {"time":"2026-11-10T08:00:00.000Z","level":"info","msg":"round finished","winner":"blue"}
//
// JSON logs are easy to search and filter in AWS CloudWatch Logs
// (e.g. { $.level = "error" }). The app only writes to stdout; systemd saves
// the output to a file and the CloudWatch agent ships that file to AWS.
// =============================================================================

function createLogger({ stream = process.stdout, silent = false } = {}) {
  function write(level, msg, fields) {
    if (silent) return;
    const line = { time: new Date().toISOString(), level, msg, ...fields };
    stream.write(JSON.stringify(line) + '\n');
  }
  return {
    info: (msg, fields) => write('info', msg, fields),
    warn: (msg, fields) => write('warn', msg, fields),
    error: (msg, fields) => write('error', msg, fields),
  };
}

module.exports = { createLogger };
