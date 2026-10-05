// Background worker (§19): a steady, modest Postgres + Redis workload so the
// deployed stack looks like production rather than a hello-world container.
const { Pool } = require("pg");
const Redis = require("ioredis");

const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 4 });
const redis = new Redis(process.env.REDIS_URL ?? "redis://redis:6379");
const INTERVAL = Number(process.env.WORKER_INTERVAL_MS ?? 5000);

async function tick() {
  await pool.query(
    `CREATE TABLE IF NOT EXISTS worker_runs (
       id SERIAL PRIMARY KEY, ran_at TIMESTAMPTZ NOT NULL DEFAULT now())`,
  );
  await pool.query("INSERT INTO worker_runs DEFAULT VALUES");
  // Keep the table bounded so the worker is not itself a disk-growth source.
  await pool.query(
    "DELETE FROM worker_runs WHERE id < (SELECT max(id) - 1000 FROM worker_runs)",
  );
  await redis.set("worker:heartbeat", new Date().toISOString(), "EX", 60);
}

async function main() {
  for (;;) {
    try {
      await tick();
    } catch (err) {
      console.error("worker tick failed:", err.message);
    }
    await new Promise((r) => setTimeout(r, INTERVAL));
  }
}

main();
