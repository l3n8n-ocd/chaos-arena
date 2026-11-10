'use strict';
// =============================================================================
// config.js — reads ALL settings from environment variables in one place.
//
// Why environment variables? The same code runs on my laptop and on the AWS
// server; only the settings differ. Nothing secret is ever written in the code
// or pushed to GitHub (see .env.example for the full list).
// =============================================================================

const path = require('node:path');

/** Read a whole number from the environment, with a default and safe limits. */
function readInt(env, name, fallback, min, max) {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  const value = Number.parseInt(raw, 10);
  if (Number.isNaN(value) || value < min || value > max) {
    throw new Error(`Config error: ${name} must be a whole number between ${min} and ${max} (got "${raw}")`);
  }
  return value;
}

function loadConfig(env = process.env) {
  const store = (env.STORE || 'file').toLowerCase();
  if (!['memory', 'file', 'dynamo'].includes(store)) {
    throw new Error(`Config error: STORE must be "memory", "file" or "dynamo" (got "${store}")`);
  }

  const config = {
    nodeEnv: env.NODE_ENV || 'development',
    host: env.HOST || '127.0.0.1',
    port: readInt(env, 'PORT', 3000, 1, 65535),

    // Where game data is kept:
    //   memory -> nowhere (tests)      file -> a local JSON file (my laptop)
    //   dynamo -> AWS DynamoDB (the real server)
    store,
    dataFile: env.DATA_FILE || path.join(__dirname, '..', '.data', 'store.json'),
    region: env.AWS_REGION || '',
    tableName: env.TABLE_NAME || '',
    bucketName: env.BUCKET_NAME || '', // optional: S3 bucket for backups

    // Game rules
    winAt: readInt(env, 'WIN_AT', 50, 5, 1000),
    chaosCooldownSec: readInt(env, 'CHAOS_COOLDOWN_SEC', 60, 5, 86400),

    // Secret token for the admin "reset game" endpoint. Empty = endpoint disabled.
    adminToken: env.ADMIN_TOKEN || '',

    // In production Nginx serves the web page; locally Express does it.
    serveStatic: (env.SERVE_STATIC || (env.NODE_ENV === 'production' ? 'false' : 'true')) === 'true',
  };

  if (config.store === 'dynamo') {
    if (!config.region) throw new Error('Config error: AWS_REGION is required when STORE=dynamo');
    if (!config.tableName) throw new Error('Config error: TABLE_NAME is required when STORE=dynamo');
  }
  if (config.adminToken && config.adminToken.length < 16) {
    throw new Error('Config error: ADMIN_TOKEN must be at least 16 characters');
  }
  return config;
}

/** A copy of the config that is safe to print in logs (secrets hidden). */
function describeConfig(config) {
  return { ...config, adminToken: config.adminToken ? '***set***' : '(not set)' };
}

module.exports = { loadConfig, describeConfig };
