'use strict';
// =============================================================================
// server.js — starts Chaos Arena.
//
//   1. read the settings (environment variables)
//   2. connect to the data store (DynamoDB on AWS, a JSON file on my laptop)
//   3. load the saved game and finish any crash that was in progress
//   4. start listening for players
//
// If this process dies (for example because someone pressed CHAOS), systemd
// starts it again automatically. See module-03-cloud-services/systemd/.
// =============================================================================

const { loadConfig, describeConfig } = require('./src/config');
const { createLogger } = require('./src/logger');
const { Game } = require('./src/game');
const { MemoryStore } = require('./src/store-memory');
const { createBackup } = require('./src/backup-s3');
const { createArena } = require('./src/app');

async function main() {
  const logger = createLogger();
  const config = loadConfig();
  logger.info('starting chaos arena', { config: describeConfig(config), node: process.version, pid: process.pid });

  let store;
  if (config.store === 'dynamo') {
    // Loaded only when needed, so local development doesn't touch the AWS SDK.
    const { DynamoStore } = require('./src/store-dynamo');
    store = new DynamoStore({ region: config.region, tableName: config.tableName });
  } else {
    store = new MemoryStore({ file: config.store === 'file' ? config.dataFile : null });
  }

  const backup = createBackup({ region: config.region, bucketName: config.bucketName, logger });
  const game = new Game({ winAt: config.winAt });

  const arena = createArena({
    config,
    game,
    store,
    backup,
    logger,
    // The "crash": exit with an error code, exactly like a real failure would.
    crash: () => {
      logger.error('process exiting with code 1 (deliberate crash)');
      process.exit(1);
    },
  });

  await arena.init();

  const server = arena.app.listen(config.port, config.host, () => {
    logger.info('listening', { url: `http://${config.host}:${config.port}`, store: store.kind });
  });

  // Graceful shutdown for planned restarts/deploys (NOT used by the chaos crash):
  // stop taking requests, save the game, then exit cleanly.
  let shuttingDown = false;
  async function shutdown(signal) {
    if (shuttingDown) return;
    shuttingDown = true;
    logger.info('shutting down gracefully', { signal });
    server.close();
    try {
      await arena.stop();
    } finally {
      process.exit(0);
    }
  }
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

// Any error nobody handled is logged, then the process exits so systemd can
// restart it in a clean state.
process.on('uncaughtException', (err) => {
  console.error(JSON.stringify({ time: new Date().toISOString(), level: 'error', msg: 'uncaught exception', error: err.stack }));
  process.exit(1);
});
process.on('unhandledRejection', (err) => {
  console.error(JSON.stringify({ time: new Date().toISOString(), level: 'error', msg: 'unhandled rejection', error: String(err?.stack || err) }));
  process.exit(1);
});

main().catch((err) => {
  console.error(JSON.stringify({ time: new Date().toISOString(), level: 'error', msg: 'failed to start', error: err.message }));
  process.exit(1);
});
