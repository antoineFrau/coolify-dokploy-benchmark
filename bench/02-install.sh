#!/usr/bin/env bash
# §5 -- install the platform under test. One VM, one platform, official installer.
#   02-install.sh coolify | dokploy | control
# "control" installs Docker only: it gives the no-platform reference point, so
# "platform overhead" can be stated as a difference rather than a guess.
source "$(dirname "$(readlink -f "$0")")/lib.sh"

target="${1:?usage: 02-install.sh <coolify|dokploy|control>}"
echo "$target" > "$PLATFORM_FILE"

snap install before --no-containers >/dev/null
t0=$(now)

case "$target" in
  coolify)
    info "installing Coolify (official installer)"
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o /tmp/coolify-install.sh
    sudo bash /tmp/coolify-install.sh
    ;;
  dokploy)
    info "installing Dokploy (official installer)"
    curl -fsSL https://dokploy.com/install.sh -o /tmp/dokploy-install.sh
    sudo sh /tmp/dokploy-install.sh
    ;;
  control)
    info "installing Docker only (no control plane)"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sudo sh /tmp/get-docker.sh
    sudo usermod -aG docker "$USER"
    ;;
  *) die "unknown target '$target'" ;;
esac

dur=$(since "$t0")
info "install finished in ${dur}s"

# Neither platform's installer adds the login user to the docker group, and a
# snapshot that cannot reach the daemon records zero containers and zero image
# size rather than failing loudly. (snapshot.py also falls back to sudo.)
sudo usermod -aG docker "$USER" 2>/dev/null || true

# Record the exact software versions -- §2 requires these to match where they can.
versions=$(cat <<JSON
{
  "target": "$target",
  "install_seconds": $dur,
  "docker_version": "$(docker --version 2>/dev/null | head -1 | sed 's/"/\\"/g')",
  "docker_compose_version": "$(docker compose version 2>/dev/null | head -1 | sed 's/"/\\"/g')",
  "kernel": "$(uname -r)",
  "os": "$(. /etc/os-release; echo "$PRETTY_NAME")"
}
JSON
)
write_summary install "$versions"

snap install after --no-containers --du >/dev/null
info "now reboot the VM, wait 5 minutes, then run 03-post-install.sh"
