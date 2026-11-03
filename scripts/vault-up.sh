#!/usr/bin/env bash
# scripts/vault-up.sh — cold start: seal stack, then vault-1.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

"$VCRY_ROOT/scripts/seal-up.sh"
ensure_seal_token_volume

"$VCRY_ROOT/scripts/compose.sh" vault up -d
vault_node vault-1
vault_wait active
echo "vault-up: vault-1 active"
