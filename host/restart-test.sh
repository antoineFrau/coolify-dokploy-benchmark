#!/usr/bin/env bash
# §14 -- reboot recovery, timed from the host so the clock covers the whole reboot.
#   restart-test.sh <vm-name> <app-url-path> <marker> [--dashboard-path /]
source "$(dirname "$(dirname "$(readlink -f "$0")")")/lib.sh"

name="${1:?usage: restart-test.sh <vm> <app-path> <marker>}"
app_path="${2:-/api/items}"; marker="${3:?expected marker}"
dash_path="${4:-/}"
platform="$(vm_ssh "$name" "cat /opt/bench/platform 2>/dev/null" 2>/dev/null || echo unknown)"
app_url="http://127.0.0.1:$(vm_http "$name")${app_path}"
dash_url="http://127.0.0.1:$(vm_ui_host "$name")${dash_path}"

poll() {  # poll <url> <deadline-epoch> [grep-pattern]
    local url="$1" deadline="$2" pat="${3:-}"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if [ -n "$pat" ]; then
            curl -fsS --max-time 5 "$url" 2>/dev/null | grep -q "$pat" && return 0
        else
            curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null && return 0
        fi
        sleep 2
    done
    return 1
}

info "$name: rebooting"
t0=$(date +%s)
vm_ssh "$name" "sudo systemctl reboot" >/dev/null 2>&1 || true

# Confirm the VM is actually down before probing for recovery -- otherwise a slow
# shutdown lets the pre-reboot system answer and the whole measurement reads as a
# few seconds when nothing has restarted yet.
down_at=""
for _ in $(seq 60); do
    if ! vm_ssh "$name" true 2>/dev/null; then down_at=$(( $(date +%s) - t0 )); break; fi
    sleep 1
done
[ -n "$down_at" ] || die "$name never went down after the reboot command"
info "$name: went down after ${down_at}s"

deadline=$(( t0 + 900 ))
vm_wait_ssh "$name" 900; ssh_s=$(( $(date +%s) - t0 ))
info "$name: ssh back after ${ssh_s}s"

# Sanity check: the guest's own uptime must be smaller than the elapsed wall clock,
# or we are talking to a system that never rebooted.
guest_uptime=$(vm_ssh "$name" "cut -d. -f1 /proc/uptime")
[ "$guest_uptime" -le "$ssh_s" ] || \
    echo "warning: guest uptime ${guest_uptime}s exceeds measured ${ssh_s}s -- did it reboot?" >&2

if [ "$platform" = control ]; then
    # The control VM has no control plane, so there is no dashboard to wait for.
    dash_s=null
    info "$name: no dashboard (control run)"
elif poll "$dash_url" "$deadline"; then
    dash_s=$(( $(date +%s) - t0 ))
    info "$name: dashboard after ${dash_s}s"
else
    dash_s=null
    info "$name: dashboard never came back within the deadline"
fi

poll "$app_url" "$deadline" "$marker" && app_s=$(( $(date +%s) - t0 )) || app_s=null
info "$name: app after ${app_s}s"

sleep 120  # let the box settle before reading memory
vm_ssh "$name" "cd /opt/bench && source lib.sh && snap restart after-reboot --du --top 20" >/dev/null
failed=$(vm_ssh "$name" "docker ps -a --filter status=exited --filter status=dead --format '{{.Names}}' | paste -sd, -" 2>/dev/null || echo "")
mem=$(vm_ssh "$name" "python3 -c \"import json;r=json.loads(open('/opt/bench/results/restart.jsonl').read().strip().splitlines()[-1]);print(r['mem']['used_mb'],r['mem']['available_mb'])\"")

out="$(result_dir "$name")/restart.json"
cat > "$out" <<JSON
{
  "vm": "$name",
  "platform": "$platform",
  "went_down_after_seconds": $down_at,
  "ssh_ready_seconds": $ssh_s,
  "guest_uptime_at_ssh_s": $guest_uptime,
  "dashboard_ready_seconds": $dash_s,
  "app_ready_seconds": $app_s,
  "ram_used_mb_after_reboot": $(echo "$mem" | awk '{print $1}'),
  "ram_available_mb_after_reboot": $(echo "$mem" | awk '{print $2}'),
  "containers_not_running_after": "$failed"
}
JSON
python3 -m json.tool "$out"
