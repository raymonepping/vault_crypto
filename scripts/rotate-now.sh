#!/usr/bin/env bash
# scripts/rotate-now.sh <seal|app> <role> — force one secret-id rotation.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

plane=${1:?Usage: rotate-now.sh <seal|app> <role>}
role=${2:?Usage: rotate-now.sh <seal|app> <role>}

case "$plane" in
seal) container=vcry-seal-rotator ;;
app)  container=vcry-rotator ;;
*) echo "rotate-now: unknown plane '$plane'" >&2; exit 64 ;;
esac

[ "$(vcry_container_state "$container")" = running ] || {
  echo "rotate-now: $container is not running" >&2; exit 1
}
touch_dir="/run/approle/$role"
podman exec "$container" sh -c "mkdir -p $touch_dir && touch $touch_dir/rotate-now"
echo "rotate-now: marker written; $container will rotate $role on its next pass (~60s)"
