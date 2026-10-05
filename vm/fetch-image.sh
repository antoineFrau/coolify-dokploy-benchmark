#!/usr/bin/env bash
# Download the Ubuntu 24.04 cloud image once; every VM uses it as a backing file.
source "$(dirname "$(dirname "$(readlink -f "$0")")")/lib.sh"

mkdir -p "$IMG_DIR" "$RUN_DIR"
base="$IMG_DIR/$UBUNTU_IMG"

if [ -f "$base" ]; then
    info "base image already present: $base"
else
    info "downloading $UBUNTU_URL"
    wget -q --show-progress -O "$base.part" "$UBUNTU_URL"
    mv "$base.part" "$base"
fi

if [ ! -f "$KEY" ]; then
    info "generating benchmark ssh key"
    ssh-keygen -t ed25519 -N '' -C bench@host -f "$KEY" >/dev/null
fi

qemu-img info "$base" | sed 's/^/    /'
