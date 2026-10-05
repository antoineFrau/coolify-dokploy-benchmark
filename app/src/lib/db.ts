import { Pool } from "pg";
import Redis from "ioredis";

declare global {
  // eslint-disable-next-line no-var
  var __pool: Pool | undefined;
  // eslint-disable-next-line no-var
  var __redis: Redis | undefined;
}

export const pool =
  global.__pool ??
  new Pool({
    connectionString: process.env.DATABASE_URL,
    max: 10,
  });
global.__pool = pool;

export const redis =
  global.__redis ?? new Redis(process.env.REDIS_URL ?? "redis://redis:6379");
global.__redis = redis;

let ready: Promise<void> | undefined;

/** Idempotent schema + seed, so the stack is self-contained on both platforms. */
export function ensureSchema(): Promise<void> {
  ready ??= (async () => {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS items (
        id    SERIAL PRIMARY KEY,
        name  TEXT NOT NULL,
        value INTEGER NOT NULL
      )
    `);
    const { rows } = await pool.query<{ count: string }>(
      "SELECT count(*)::text AS count FROM items",
    );
    if (rows[0].count === "0") {
      await pool.query(
        `INSERT INTO items (name, value)
         SELECT 'item-' || g, g FROM generate_series(1, 500) AS g`,
      );
    }
  })();
  return ready;
}
