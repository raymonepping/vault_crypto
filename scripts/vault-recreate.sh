#!/usr/bin/env bash
# scripts/vault-recreate.sh — recreate vault-1 keeping its data volumes,
# so it starts on the seal agent's current token instead of the bootstrap.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

[ "$(vcry_container_state vcry-vault-1)" = running ] || {
  echo "vault-recreate: vault-1 is not running" >&2; exit 1
}
"$VCRY_ROOT/scripts/compose.sh" vault up -d --force-recreate vault-1
vault_node vault-1
vault_wait active
echo "vault-recreate: vault-1 restarted"
"$VCRY_ROOT/scripts/seal-token-status.sh"
