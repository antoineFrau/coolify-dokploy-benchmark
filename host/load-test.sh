#!/usr/bin/env bash
# §11 -- HTTP load against a VM's app, generated on the host with k6 (via Docker),
# while the VM samples its own CPU/RAM. Default sweep: 10, 50, 100, 200 connections.
#
#   load-test.sh <vm-name> [--path /api/items] [--conns "10 50 100 200"]
#                [--duration 60s] [--port <host-port>] [--tag <label>]
#
# Note the host networking caveat: QEMU user-mode networking sits between the host
# and the guest, so absolute requests/sec is capped by the emulated NIC rather than
# by the app. Both VMs are measured through the identical path, so the comparison
# holds; treat the absolute rps as a floor, not as the D2-8's capacity. For an
# uncapped in-guest figure as well, pass --also-in-vm.
source "$(dirname "$(dirname "$(readlink -f "$0")")")/lib.sh"

name="${1:?usage: load-test.sh <vm-name> [options]}"; shift
path="/api/items"; conns="10 50 100 200"; duration="60s"; tag=""; in_vm=0
port="$(vm_http "$name")"
while [ $# -gt 0 ]; do
    case "$1" in
        --path) path="$2"; shift 2 ;;
        --conns) conns="$2"; shift 2 ;;
        --duration) duration="$2"; shift 2 ;;
        --port) port="$2"; shift 2 ;;
        --tag) tag="$2"; shift 2 ;;
        --also-in-vm) in_vm=1; shift ;;
        *) die "unknown option $1" ;;
    esac
done

out="$(result_dir "$name")/load${tag:+-$tag}"
mkdir -p "$out"
target="http://127.0.0.1:${port}${path}"

info "$name: warming up $target"
curl -fsS --max-time 10 "$target" >/dev/null || die "target not reachable: $target"

for c in $conns; do
    info "$name: k6 ${c} VUs for $duration against $target"
    run_out="$out/c$c"; mkdir -p "$run_out"

    # Sample inside the VM for the duration of the run (§11 asks for docker stats
    # and vmstat during the benchmark).
    vm_ssh "$name" "cd /opt/bench && source lib.sh && monitor_stop load-c$c; monitor_start load-c$c 2" >/dev/null
    vm_ssh "$name" "vmstat 1 </dev/null >/opt/bench/results/load-c$c.vmstat.log 2>&1 & echo \$! > /tmp/vmstat-c$c.pid" >/dev/null

    # Run as the invoking user so k6 can write its summary into results/.
    docker run --rm --network host --user "$(id -u):$(id -g)" \
        -v "$ROOT/host/k6-script.js:/script.js:ro" -v "$run_out:/out" \
        -e TARGET="$target" -e CONNS="$c" -e DURATION="$duration" \
        grafana/k6:latest run /script.js 2>"$run_out/k6.log" | tail -20

    vm_ssh "$name" "kill \$(cat /tmp/vmstat-c$c.pid) 2>/dev/null; cd /opt/bench && source lib.sh && monitor_stop load-c$c" >/dev/null

    # Fold the VM-side resource usage into the same directory as the k6 result.
    vm_ssh "$name" "python3 /opt/bench/summarize_window.py /opt/bench/results/load-c$c.jsonl" \
        > "$run_out/vm-resources.json" 2>/dev/null || true
    info "$name: c=$c done -> $run_out"
done

if [ "$in_vm" = 1 ]; then
    info "$name: repeating the heaviest level from inside the VM (no slirp in the path)"
    hi=$(echo $conns | tr ' ' '\n' | sort -n | tail -1)
    vm_ssh "$name" "docker run --rm --network host -e TARGET=http://127.0.0.1${path} \
        -e CONNS=$hi -e DURATION=$duration -v /opt/bench/k6-script.js:/script.js:ro \
        -v /opt/bench/results:/out grafana/k6:latest run /script.js" \
        > "$out/in-vm-c$hi.txt" 2>&1 || echo "in-VM run failed; see $out/in-vm-c$hi.txt" >&2
fi

info "$name: load results under $out"
