#!/usr/bin/env bash
# §12 -- how many realistic applications fit before RAM gets uncomfortable.
# Deploy app copy N in the dashboard, wait for it to be healthy, then:
#   06-memory-pressure.sh record <n>
# The verdict uses the thresholds from the protocol and is printed after each record.
source "$(dirname "$(readlink -f "$0")")/lib.sh"

cmd="${1:?usage: 06-memory-pressure.sh record <app-count>}"
[ "$cmd" = record ] || die "unknown command '$cmd'"
n="${2:?app count}"

snap memory-pressure "apps-$n" --du --top 20 >/dev/null
python3 - "$RES/memory-pressure.jsonl" "$n" <<'PY'
import json, sys
row = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
avail = row["mem"]["available_mb"]
verdict = ("comfortable" if avail > 2048 else
           "acceptable"  if avail > 1024 else
           "risky"       if avail > 500  else
           "too close to the limit")
print(json.dumps({
    "apps": int(sys.argv[2]),
    "available_mb": avail,
    "used_mb": row["mem"]["used_mb"],
    "swap_used_mb": row["swap"]["used_mb"],
    "container_mem_mb": round(row.get("container_mem_bytes", 0) / 1048576),
    "containers": len(row.get("containers", [])),
    "verdict": verdict,
}, indent=2))
PY
