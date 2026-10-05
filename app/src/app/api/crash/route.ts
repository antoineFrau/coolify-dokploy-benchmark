import { NextResponse } from "next/server";

export const dynamic = "force-dynamic";

/**
 * §15 failure test: make the web process die the way a real crash would.
 *
 * `docker kill` is not usable for this on Docker 29 -- the daemon treats an
 * externally delivered SIGKILL as an intentional stop and does not apply the
 * restart policy, so every platform would score "never recovered" for a reason
 * that has nothing to do with the platform. Exiting non-zero from inside the
 * container is a genuine crash, and it exercises exactly what is being compared:
 * the platform's restart policy, health checks and status reporting.
 */
export async function GET() {
  setTimeout(() => process.exit(1), 50);
  return NextResponse.json({ crashing: true }, { status: 500 });
}
