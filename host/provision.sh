#!/usr/bin/env bash
# provision.sh <vm-name> [platform] -- copy the benchmark scripts and the test app
# into the VM at /opt/bench, and install the §3 monitoring tools.
source "$(dirname "$(dirname "$(readlink -f "$0")")")/lib.sh"

name="${1:?usage: provision.sh <vm-name> [coolify|dokploy|control]}"
platform="${2:-$(vm_platform "$name")}"

vm_wait_ssh "$name"
info "$name: copying harness to /opt/bench"
vm_ssh "$name" "sudo mkdir -p /opt/bench && sudo chown ubuntu:ubuntu /opt/bench"

tar -C "$ROOT/bench" -cz . | vm_ssh "$name" "tar -C /opt/bench -xz"
tar -C "$ROOT" -cz app    | vm_ssh "$name" "tar -C /opt/bench -xz"
# The in-guest variant of the load test (host/load-test.sh --also-in-vm) runs the
# same k6 script, so it travels with the harness.
tar -C "$ROOT/host" -cz k6-script.js | vm_ssh "$name" "tar -C /opt/bench -xz"
vm_ssh "$name" "chmod +x /opt/bench/*.sh /opt/bench/*.py && echo '$platform' > /opt/bench/platform"

info "$name: installing monitoring tools (§3)"
vm_ssh "$name" "/opt/bench/00-tools.sh"
info "$name: provisioned for '$platform'"
