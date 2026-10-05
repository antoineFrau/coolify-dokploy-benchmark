import { topItems } from "@/lib/items";
import { BUILD_MARKER } from "@/lib/build-marker";

export const dynamic = "force-dynamic";

export default async function Page() {
  const { items, cached } = await topItems();
  return (
    <main>
      <h1>Benchmark app</h1>
      <p>
        {items.length} items · {cached ? "redis hit" : "postgres read"} ·{" "}
        {BUILD_MARKER}
      </p>
      <ul>
        {items.slice(0, 10).map((i) => (
          <li key={i.id}>
            {i.name} = {i.value}
          </li>
        ))}
      </ul>
    </main>
  );
}
