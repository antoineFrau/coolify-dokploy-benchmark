import { ensureSchema, pool, redis } from "./db";

export type Item = { id: number; name: string; value: number };

const CACHE_KEY = "items:top";
const CACHE_TTL = 10; // seconds

/**
 * Representative read path: Redis cache in front of a Postgres query.
 * This is what the §11 load test hammers, so it exercises web + cache + db.
 */
export async function topItems(): Promise<{ items: Item[]; cached: boolean }> {
  await ensureSchema();

  const hit = await redis.get(CACHE_KEY);
  if (hit) return { items: JSON.parse(hit) as Item[], cached: true };

  const { rows } = await pool.query<Item>(
    "SELECT id, name, value FROM items ORDER BY value DESC LIMIT 20",
  );
  await redis.set(CACHE_KEY, JSON.stringify(rows), "EX", CACHE_TTL);
  return { items: rows, cached: false };
}
