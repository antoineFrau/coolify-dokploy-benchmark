#!/usr/bin/env bash
# reset-results.sh <vm-name> [--local-too] -- stop any stray samplers and clear the
# VM's collected measurements. Run it between benchmark runs so a phase cannot
# silently append to data from a previous attempt.
source "$(dirname "$(dirname "$(readlink -f "$0")")")/lib.sh"

name="${1:?usage: reset-results.sh <vm-name> [--local-too]}"

vm_ssh "$name" 'for p in /opt/bench/results/*.monitor.pid; do
    [ -f "$p" ] || continue
    pid=$(cat "$p"); kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
done
pkill -x vmstat 2>/dev/null
rm -rf /opt/bench/results && mkdir -p /opt/bench/results' || true
info "$name: in-VM results cleared"

if [ "${2:-}" = "--local-too" ]; then
    rm -rf "$RESULTS/$name"
    info "$name: local results/$name removed"
fi
