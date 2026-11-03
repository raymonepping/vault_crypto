#!/usr/bin/env bash
# scripts/vault-status.sh — one row per Vault node. Read-only.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

printf '%-9s %-12s %-6s %-7s %-8s %-9s %-8s %s\n' NODE CONTAINER INIT SEALED SEAL HA RAFT VERSION
for node in vault-s vault-1; do
  cstate=$(vcry_container_state "$(vault_container "$node")")
  if [ "$cstate" != running ]; then
    printf '%-9s %-12s\n' "$node" "$cstate"
    continue
  fi
  vault_node "$node"
  if ! s=$(vault_json 2>/dev/null); then
    printf '%-9s %-12s %s\n' "$node" "$cstate" "unreachable"
    continue
  fi
  ha=-
  if jq -e '.initialized and (.sealed | not)' <<<"$s" >/dev/null; then
    ha=$(curl -sf --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/sys/leader" | jq -r 'if .is_self then "active" else "standby" end' 2>/dev/null || echo -)
  fi
  printf '%-9s %-12s %-6s %-7s %-8s %-9s %-8s %s\n' "$node" "$cstate" \
    "$(jq -r .initialized <<<"$s")" "$(jq -r .sealed <<<"$s")" "$(jq -r .type <<<"$s")" \
    "$ha" "$(jq -r '.raft_committed_index // "-"' <<<"$s")" "$(jq -r .version <<<"$s")"
done
