#!/usr/bin/env bash
# scripts/app-build.sh [api|web …] — build the app images.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
export COPYFILE_DISABLE=1

targets=${*:-api web}
prefix=$(vcry_conf VCRY_IMAGE_PREFIX)
tag=$(vcry_conf VCRY_IMAGE_TAG)

for t in $targets; do
  case "$t" in
  api) ctx="$VCRY_ROOT/api" ;;
  web) ctx="$VCRY_ROOT/web" ;;
  *) echo "app-build: unknown target '$t'" >&2; exit 64 ;;
  esac
  xattr -rc "$ctx" 2>/dev/null || true
  find "$ctx" -name '._*' -not -path '*/node_modules/*' -delete 2>/dev/null || true
  echo "app-build: building $prefix/$t:$tag"
  podman build -q --format docker \
    --build-arg NODE_IMAGE="$(vcry_conf NODE_IMAGE)" \
    --build-arg NGINX_IMAGE="$(vcry_conf NGINX_IMAGE)" \
    -t "$prefix/$t:$tag" -f "$ctx/Containerfile" "$ctx" >/dev/null
done
