#!/usr/bin/env bash
# §15 -- break the application and measure how the platform reacts.
#
#   08-failure.sh <app-url> <marker> [container-substring] [--crash|--kill|--docker-restart]
#
#     --crash           (default) hit /api/crash so the web process exits non-zero.
#                       Docker 29 does NOT apply a restart policy after an external
#                       `docker kill` -- it treats the signal as an intentional stop --
#                       so a real in-process crash is the only way to measure the
#                       platform's recovery instead of that quirk.
#     --kill            `docker kill` the container. Worth running once for the record;
#                       expect "not restarted" on both platforms, for the reason above.
#     --docker-restart  restart the Docker daemon and time the whole stack's comeback.
#
# Recovery is measured twice: user-visible HTTP downtime (probed at 20 Hz, because a
# restart can be sub-second) and Docker's own RestartCount/StartedAt.
source "$(dirname "$(readlink -f "$0")")/lib.sh"

url="${1:?app url}"; marker="${2:?expected marker}"; filter="${3:-web}"
mode="${4:---crash}"

target=$(docker ps --format '{{.Names}}' | grep -i "$filter" | head -1 || true)
[ -n "$target" ] || die "no running container matching '$filter'"

snap failure before >/dev/null
monitor_start failure 2

info "$(platform): ${mode#--} test against $target"
probe=$(python3 "$BENCH/failure_probe.py" "$url" "$marker" "$target" \
            --mode "${mode#--}" || echo '{"error":"probe failed"}')

monitor_stop failure
snap failure after >/dev/null

failed=$(docker ps -a --filter status=exited --filter status=dead --format '{{.Names}}' | paste -sd, -)

write_summary "failure-${mode#--}" "$(python3 - <<PY
import json
print(json.dumps({
    "platform": "$(platform)",
    "probe": json.loads('''$probe'''),
    "containers_not_running_after": [c for c in "$failed".split(",") if c],
}, indent=2))
PY
)"

echo
echo "Record by hand from the dashboard (§15 asks for these and no script can judge them):"
echo "  - did the platform surface the failure at all?"
echo "  - was the status it displayed accurate?"
echo "  - how long until the dashboard reflected reality?"
