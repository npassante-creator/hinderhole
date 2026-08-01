/**
 * db.js
 * Single shared Postgres pool. Exposes query() and connect() so auth.js
 * can grab a client for transactions.
 */

'use strict';

const { Pool } = require('pg');

if (!process.env.DATABASE_URL) {
  console.error('DATABASE_URL is not set. Check your .env file.');
  process.exit(1);
}

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

pool.on('error', (err) => {
  console.error('[db] idle client error', err);
});

module.exports = pool;
