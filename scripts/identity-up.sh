#!/usr/bin/env bash
# scripts/identity-up.sh — start the identity stack (OpenLDAP + Keycloak).
# Secrets first (create-only, in Vault KV), then the one-shot init that renders
# them, then the directory and Keycloak. First time: make identity-bootstrap.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
"$VCRY_ROOT/scripts/identity-secrets.sh"
"$VCRY_ROOT/scripts/compose.sh" identity up -d
for _ in $(seq 1 60); do
  [ "$(podman inspect vcry-keycloak --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] && break
  sleep 3
done
[ "$(podman inspect vcry-keycloak --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] ||
  {
    echo "identity-up: Keycloak did not become healthy (make identity-logs)" >&2
    exit 1
  }
echo "identity-up: OpenLDAP and Keycloak ready (http://localhost:$(vcry_conf VCRY_PORT_KEYCLOAK))"
