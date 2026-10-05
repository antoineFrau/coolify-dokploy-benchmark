#!/usr/bin/env bash
# start-vm.sh <vm-name> [--wait] -- boot the VM under KVM with the benchmark spec.
source "$(dirname "$(dirname "$(readlink -f "$0")")")/lib.sh"

name="${1:?usage: start-vm.sh <vm-name> [--wait]}"
wait_ssh="${2:-}"
d="$(vm_dir "$name")"
[ -f "$d/disk.qcow2" ] || die "$name has no disk; run vm/create-vm.sh $name"
vm_running "$name" && { info "$name already running (pid $(vm_pid "$name"))"; exit 0; }
rm -f "$d/qemu.pid"

ssh_p="$(vm_ssh_port "$name")"; http_p="$(vm_http "$name")"
https_p="$(vm_https "$name")"; ui_h="$(vm_ui_host "$name")"; ui_g="$(vm_ui_guest "$name")"

fwd="hostfwd=tcp::${ssh_p}-:22,hostfwd=tcp::${http_p}-:80,hostfwd=tcp::${https_p}-:443,hostfwd=tcp::${ui_h}-:${ui_g}"

# Platform-specific extras (Coolify's realtime and terminal ports, for instance):
# without them the dashboard half-works and the §16 usability notes are unfair.
extra="$(vm_extra_fwd "$name")"
if [ "$extra" != "-" ]; then
    IFS=',' read -ra pairs <<< "$extra"
    for pair in "${pairs[@]}"; do
        fwd="$fwd,hostfwd=tcp::${pair%%:*}-:${pair##*:}"
    done
fi

# cache=none keeps the host page cache out of the disk and build measurements, so the
# two platforms are compared on real I/O. Fall back if the filesystem rejects O_DIRECT.
boot() {
    local cache="$1"
    qemu-system-x86_64 \
        -name "$name" -enable-kvm -cpu host -smp "$VM_CPUS" -m "$VM_MEM" \
        -drive "file=$d/disk.qcow2,if=virtio,format=qcow2,cache=$cache,discard=unmap" \
        -drive "file=$d/seed.iso,if=virtio,format=raw,readonly=on" \
        -netdev "user,id=n0,$fwd" -device virtio-net-pci,netdev=n0 \
        -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
        -display none -serial "file:$d/console.log" \
        -monitor "unix:$d/monitor.sock,server,nowait" \
        -pidfile "$d/qemu.pid" -daemonize
}

# Fail early and clearly on a port clash: QEMU's own message ("Could not set up
# host forwarding rule") does not say who is already holding the port.
for p in $(echo "$fwd" | tr ',' '\n' | sed 's/hostfwd=tcp:://; s/-:.*//'); do
    if ss -ltn "sport = :$p" 2>/dev/null | grep -q ":$p"; then
        die "$name: host port $p is already in use -- change it in vms.conf"
    fi
done

info "$name: booting ${VM_CPUS} vCPU / ${VM_MEM}M / ${VM_DISK}"
boot none 2>"$d/qemu.err" || {
    grep -qi 'direct\|O_DIRECT\|Invalid argument' "$d/qemu.err" || { cat "$d/qemu.err" >&2; exit 1; }
    info "$name: O_DIRECT unavailable, falling back to cache=writeback (note it in the report)"
    boot writeback || { cat "$d/qemu.err" >&2; exit 1; }
}

echo "    ssh:       ssh -i $KEY -p $ssh_p ubuntu@127.0.0.1   (or vm/ssh.sh $name)"
echo "    http:      http://127.0.0.1:$http_p"
echo "    dashboard: http://127.0.0.1:$ui_h"

if [ "$wait_ssh" = "--wait" ]; then
    info "$name: waiting for ssh + cloud-init"
    vm_wait_ssh "$name"
    vm_ssh "$name" "cloud-init status --wait >/dev/null 2>&1 || true"
    info "$name: up"
fi
