#!/usr/bin/env bash
# create-vm.sh <vm-name> -- build a fresh 50G overlay disk + cloud-init seed for a VM.
# Destroys any previous disk for that VM, so every benchmark run starts identical.
source "$(dirname "$(dirname "$(readlink -f "$0")")")/lib.sh"

name="${1:?usage: create-vm.sh <vm-name>}"
vm_names | grep -qx "$name" || die "unknown VM '$name'"
vm_running "$name" && die "$name is running; stop it first"

base="$IMG_DIR/$UBUNTU_IMG"
[ -f "$base" ] || die "base image missing; run vm/fetch-image.sh"
[ -f "$KEY.pub" ] || die "ssh key missing; run vm/fetch-image.sh"

d="$(vm_dir "$name")"
rm -rf "$d"; mkdir -p "$d"

info "$name: creating 50G overlay disk"
qemu-img create -f qcow2 -F qcow2 -b "$(readlink -f "$base")" "$d/disk.qcow2" "$VM_DISK" >/dev/null

info "$name: writing cloud-init seed"
cat > "$d/meta-data" <<META
instance-id: $name
local-hostname: $name
META

cat > "$d/user-data" <<USERDATA
#cloud-config
hostname: $name
users:
  - name: ubuntu
    groups: [sudo]
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    ssh_authorized_keys:
      - $(cat "$KEY.pub")
ssh_pwauth: false
package_update: false
package_upgrade: false
# The protocol asks for swap disabled, and for a baseline that is not polluted by
# background package work. Both VMs get exactly this treatment.
swap: {}
bootcmd:
  - [ swapoff, -a ]
runcmd:
  - [ systemctl, disable, --now, unattended-upgrades ]
  - [ systemctl, disable, --now, apt-daily.timer ]
  - [ systemctl, disable, --now, apt-daily-upgrade.timer ]
  - [ sed, -i, '/\sswap\s/d', /etc/fstab ]
  - [ touch, /var/lib/cloud/instance/bench-ready ]
USERDATA

genisoimage -quiet -output "$d/seed.iso" -volid cidata -joliet -rock \
    "$d/user-data" "$d/meta-data"

info "$name: ready ($d) -- start with vm/start-vm.sh $name"
