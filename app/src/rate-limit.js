'use strict';
// =============================================================================
// rate-limit.js — a small "token bucket" rate limiter (a resource quota).
//
// Each player has a bucket of tokens. Every click costs one token; tokens
// refill at a steady rate. An empty bucket means "slow down" (HTTP 429).
// This stops scripts from flooding a tiny free-tier server and the database.
// =============================================================================

function createRateLimiter({ ratePerSec, burst, now = Date.now, maxKeys = 20000 }) {
  const buckets = new Map(); // key -> { tokens, last }

  return {
    /** Try to spend `cost` tokens for `key`. Returns true if allowed. */
    take(key, cost = 1) {
      const t = now();
      let bucket = buckets.get(key);
      if (!bucket) {
        if (buckets.size >= maxKeys) buckets.clear(); // safety valve: never grow forever
        bucket = { tokens: burst, last: t };
        buckets.set(key, bucket);
      }
      const refill = ((t - bucket.last) / 1000) * ratePerSec;
      bucket.tokens = Math.min(burst, bucket.tokens + refill);
      bucket.last = t;
      if (bucket.tokens < cost) return false;
      bucket.tokens -= cost;
      return true;
    },

    /** Forget buckets that have been idle for a while (called on a timer). */
    cleanup(idleMs = 60000) {
      const cutoff = now() - idleMs;
      for (const [key, bucket] of buckets) {
        if (bucket.last < cutoff) buckets.delete(key);
      }
    },

    get size() {
      return buckets.size;
    },
  };
}

module.exports = { createRateLimiter };
