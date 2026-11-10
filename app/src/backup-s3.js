'use strict';
// =============================================================================
// backup-s3.js — saves small JSON reports to Amazon S3 (object storage).
//
//   backups/state-latest.json        the scoreboard after every finished round
//   incidents/<crash time>.json      one report per crash + recovery
//
// S3 is a different kind of storage from DynamoDB: it stores whole files
// ("objects") cheaply and very durably, which makes it ideal for backups.
// If no bucket is configured (e.g. on my laptop) backups are simply skipped.
// =============================================================================

const { S3Client, PutObjectCommand, ListObjectsV2Command } = require('@aws-sdk/client-s3');

function createBackup({ region, bucketName, client, logger }) {
  if (!bucketName) {
    return {
      enabled: false,
      async putJson() {},
      async check() {
        return { ok: true, kind: 'none', detail: 'no bucket configured, backups skipped' };
      },
    };
  }

  const s3 = client || new S3Client({ region, maxAttempts: 3 });

  return {
    enabled: true,

    /** Upload an object as pretty JSON. Never throws: a failed backup must not break the game. */
    async putJson(key, value) {
      try {
        await s3.send(
          new PutObjectCommand({
            Bucket: bucketName,
            Key: key,
            Body: JSON.stringify(value, null, 2),
            ContentType: 'application/json',
          })
        );
        logger?.info('backup saved to S3', { bucket: bucketName, key });
      } catch (err) {
        logger?.error('backup to S3 failed', { bucket: bucketName, key, error: err.message });
      }
    },

    /** Health check: can we reach the bucket? */
    async check() {
      await s3.send(new ListObjectsV2Command({ Bucket: bucketName, MaxKeys: 1 }));
      return { ok: true, kind: 's3', detail: `bucket ${bucketName} is reachable` };
    },
  };
}

module.exports = { createBackup };
