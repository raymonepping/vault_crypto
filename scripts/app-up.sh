#!/usr/bin/env bash
# scripts/app-up.sh — build images if missing, then start the app stack.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

prefix=$(vcry_conf VCRY_IMAGE_PREFIX)
tag=$(vcry_conf VCRY_IMAGE_TAG)

for t in api web; do
  if ! podman image exists "$prefix/$t:$tag"; then
    echo "app-up: $prefix/$t:$tag not found — building"
    "$VCRY_ROOT/scripts/app-build.sh" "$t"
  fi
done

"$VCRY_ROOT/scripts/compose.sh" app up -d
echo "app-up: stack started"
echo "  UI:      https://localhost:$(vcry_conf VCRY_PORT_WEB)/   (certificate from pki-classic-int; make trust-root to trust it)"
echo "  API:     http://127.0.0.1:$(vcry_conf VCRY_PORT_API)/api/health"
echo "  Vault:   https://localhost:$(vcry_conf VCRY_PORT_VAULT_1)/ui"
