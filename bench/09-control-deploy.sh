#!/usr/bin/env bash
# Reference point, not part of the protocol's numbered sections: deploy the same
# stack with plain `docker compose`, no control plane. It turns "platform overhead"
# into a measured difference (platform+app − docker+app) instead of an estimate,
# and it is also the quickest way to smoke-test the harness end to end.
#
#   09-control-deploy.sh [marker] [host-port]
source "$(dirname "$(readlink -f "$0")")/lib.sh"

marker="${1:-build-1}"
port="${2:-80}"
app=/opt/bench/app

cd "$app"
"$app/set-marker.sh" "$marker"
info "deploying the control stack (marker=$marker, port=$port)"
CONTROL_PORT="$port" sudo -E docker compose -p bench \
    -f docker-compose.yml -f docker-compose.control.yml up -d --build

info "waiting for the stack to answer"
wait_marker "http://127.0.0.1:${port}/api/items" "\"marker\":\"$marker\"" 300 \
    && info "control stack is serving on port $port" \
    || die "control stack did not come up"
