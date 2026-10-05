#!/usr/bin/env bash
# §3 -- monitoring tools, installed identically on both VMs before any measurement.
source "$(dirname "$(readlink -f "$0")")/lib.sh"

info "installing monitoring tools"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    htop sysstat iotop curl jq git ca-certificates >/dev/null

# sysstat's collector is disabled by default on Ubuntu; mpstat/vmstat work regardless
# and we do not want a background collector writing to disk during the disk tests.
sudo systemctl disable --now sysstat 2>/dev/null || true

info "tools installed:"
for c in htop mpstat iotop curl jq git vmstat python3; do
    printf '    %-10s %s\n' "$c" "$(command -v "$c" || echo MISSING)"
done
