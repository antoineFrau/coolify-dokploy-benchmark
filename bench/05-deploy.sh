#!/usr/bin/env bash
# §8 / §9 / §10 -- measure one deployment of the test stack on the platform under test.
#
#   05-deploy.sh <mode> <url> <marker> [--trigger "<cmd>"] [--settle 300] [--timeout 1800]
#
#   mode    first | cold | warm
#           first -- §8 deployment overhead (whatever cache state exists)
#           cold  -- §9 removes the build cache first, for a true cold build
#           warm  -- §10 rebuild after a one-line source change, measures cache reuse
#   url     a URL on the deployed app that echoes the marker, e.g.
#           http://127.0.0.1/ or http://app.local/api/items
#   marker  the BENCH_MARKER value this deploy is expected to serve
#
# The deploy itself is triggered by the platform (UI or API) -- that is the thing
# being compared. Pass --trigger to automate it, otherwise the script waits for you
# to press Enter at the exact moment you start the deploy.
source "$(dirname "$(readlink -f "$0")")/lib.sh"

mode="${1:?mode: first|cold|warm}"; url="${2:?app url}"; marker="${3:?expected marker}"
shift 3
trigger=""; settle=300; timeout=1800
while [ $# -gt 0 ]; do
    case "$1" in
        --trigger) trigger="$2"; shift 2 ;;
        --settle)  settle="$2";  shift 2 ;;
        --timeout) timeout="$2"; shift 2 ;;
        *) die "unknown option $1" ;;
    esac
done

phase="deploy-$mode"

if [ "$mode" = cold ]; then
    info "cold build requested: pruning the Docker build cache"
    docker builder prune -af >/dev/null
    docker image prune -af --filter "label!=keep" >/dev/null 2>&1 || true
fi

info "pre-deploy snapshot"
snap "$phase" before --du >/dev/null
before_ts=$(python3 -c "import json;print(json.loads(open('$RES/$phase.jsonl').read().strip().splitlines()[-1])['ts'])")

monitor_start "$phase" 2
# vmstat alongside, as the protocol asks -- cheap, and it catches io wait that the
# snapshot's CPU summary flattens out.
vmstat 1 </dev/null >"$RES/$phase.vmstat.log" 2>&1 &
vmstat_pid=$!

if [ -n "$trigger" ]; then
    info "triggering deploy: $trigger"
    t0=$(now)
    eval "$trigger"
else
    echo
    echo "    >>> Start the deployment in the $(platform) dashboard now, then press Enter."
    read -r _
    t0=$(now)
fi

info "waiting for $url to serve marker '$marker' (timeout ${timeout}s)"
if wait_marker "$url" "$marker" "$timeout"; then
    t1=$(now); status=ok
else
    t1=$(now); status=timeout
    echo "warning: marker never appeared -- recording the window anyway" >&2
fi
dur=$(python3 -c "print(f'{float('$t1')-float('$t0'):.1f}')")
info "deploy ($mode) $status in ${dur}s"

kill "$vmstat_pid" 2>/dev/null || true
monitor_stop "$phase"

info "settling ${settle}s before the steady-state snapshot"
sleep "$settle"
snap "$phase" after --du >/dev/null

window=$(python3 "$BENCH/summarize_window.py" "$RES/$phase.jsonl" --from "$t0" --to "$t1")
after_ts=$(python3 -c "import json;print(json.loads(open('$RES/$phase.jsonl').read().strip().splitlines()[-1])['ts'])")

write_summary "$phase" "$(python3 - <<PY
import json
print(json.dumps({
    "platform": "$(platform)",
    "mode": "$mode",
    "status": "$status",
    "duration_seconds": float("$dur"),
    "t0": float("$t0"), "t1": float("$t1"),
    "before_ts": float("$before_ts"), "after_ts": float("$after_ts"),
    "build_window": json.loads('''$window'''),
}, indent=2))
PY
)"
