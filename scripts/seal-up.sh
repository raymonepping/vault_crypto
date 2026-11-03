#!/usr/bin/env bash
# scripts/seal-up.sh — start the seal plane in the correct order:
#   1. vault-s alone
#   2. unseal
#   3. rotator + agent (need unsealed vault-s)
#   4. wait for agent (so vault-1 finds a fresh seal token)
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
compose() { "$VCRY_ROOT/scripts/compose.sh" seal "$@"; }

"$VCRY_ROOT/scripts/network.sh"
ensure_seal_token_volume
compose up -d vault-s
"$VCRY_ROOT/scripts/vault-unseal.sh"
vault_node vault-s
vault_wait active

# Keep the bootstrap fallback token alive.
if [ -s "$VCRY_STATE/transit-token" ]; then
  VAULT_TOKEN=$(cat "$VCRY_STATE/transit-token") vault token renew >/dev/null 2>&1 ||
    echo "seal-up: note — the bootstrap fallback seal token is no longer valid (make vault-bootstrap re-issues it)"
fi

if [ -s "$VCRY_STATE/seal-rotator/secret-id" ]; then
  compose up -d
  n=0
  until [ "$(podman container inspect vcry-seal-agent --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ]; do
    n=$((n + 1))
    if [ "$n" -ge 60 ]; then
      echo "seal-up: WARNING the seal agent is not healthy after 120s; vault-1 will fall back to the bootstrap token (make agents-recover)" >&2
      exit 0
    fi
    sleep 2
  done
  echo "seal-up: seal agent healthy — fresh seal token in the sink"
else
  echo "seal-up: seal plane identity not set up yet (make tf-seal && make rotator-bootstrap)"
fi
