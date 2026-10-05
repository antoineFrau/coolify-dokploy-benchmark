import { NextResponse } from "next/server";
import { pool, redis } from "@/lib/db";

export const dynamic = "force-dynamic";

export async function GET() {
  const checks: Record<string, string> = {};
  try {
    await pool.query("SELECT 1");
    checks.postgres = "ok";
  } catch (e) {
    checks.postgres = String(e);
  }
  try {
    await redis.ping();
    checks.redis = "ok";
  } catch (e) {
    checks.redis = String(e);
  }
  const ok = Object.values(checks).every((v) => v === "ok");
  return NextResponse.json({ ok, checks }, { status: ok ? 200 : 503 });
}
