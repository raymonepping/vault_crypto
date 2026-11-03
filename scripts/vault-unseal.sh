#!/usr/bin/env bash
# scripts/vault-unseal.sh — idempotent unseal of vault-s only.
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

vault_node vault-s
INIT_FILE="$VCRY_STATE/seal-init.json"
[ -s "$INIT_FILE" ] || {
  echo "unseal: .secrets/vault/seal-init.json not found — run make vault-bootstrap first" >&2
  exit 1
}

vault_wait reachable 30
state=$(vault_json) || {
  echo "unseal: vault-s unreachable at $VAULT_ADDR" >&2
  exit 1
}

jq -e '.initialized' <<<"$state" >/dev/null || {
  echo "unseal: vault-s reports uninitialized but saved credentials exist: its volume was lost." >&2
  exit 1
}

if jq -e '.sealed | not' <<<"$state" >/dev/null; then
  echo "unseal: vault-s is already unsealed — nothing to do"
  exit 0
fi

unseal_key=$(jq -er '.unseal_keys_b64[0]' "$INIT_FILE") || {
  echo "unseal: could not read the unseal key from .secrets/vault/seal-init.json" >&2
  exit 1
}
echo "unseal: vault-s is sealed — unsealing"
vault operator unseal "$unseal_key" >/dev/null
unset unseal_key

if vault_json | jq -e '.sealed | not' >/dev/null; then
  echo "unseal: vault-s is unsealed"
else
  echo "unseal: unseal call completed but vault-s still reports sealed — the saved key does not match this storage" >&2
  exit 1
fi
