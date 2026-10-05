import { NextResponse } from "next/server";
import { topItems } from "@/lib/items";
import { BUILD_MARKER } from "@/lib/build-marker";

export const dynamic = "force-dynamic";

export async function GET() {
  const { items, cached } = await topItems();
  // marker identifies which build is live; the deploy scripts poll for it.
  return NextResponse.json({
    marker: BUILD_MARKER,
    count: items.length,
    cached,
    items,
  });
}
