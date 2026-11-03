#!/usr/bin/env bash
# scripts/license-features.sh — which licensed feature each demo room needs,
# and whether vault-1's autoloaded licence has it. Read-only. Prints feature
# names and the expiry date only, never the licence itself.
#
# Exit 0 when every required feature is present, 1 otherwise. Rooms whose
# feature is plain Vault Enterprise (no separate module) show "edition".
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

vault_node vault-1
vault_root vault
status=$(vault read -format=json sys/license/status)
version=$(vault_json | jq -r .version)
unset VAULT_TOKEN

features=$(jq -r '.data.autoloaded.features[]' <<<"$status")
has() { grep -qxF "$1" <<<"$features"; }

missing=0
row() {
  local room=$1 need=$2 got
  if [ "$need" = edition ]; then
    case "$version" in *+ent*) got="yes (Vault Enterprise $version)" ;; *) got="NO (not Enterprise)"; missing=1 ;; esac
  elif has "$need"; then
    got="yes"
  else
    got="NO"
    missing=1
  fi
  printf '  %-20s %-34s %s\n' "$room" "$need" "$got"
}

echo "vault-1 licence: expires $(jq -r '.data.autoloaded.expiration_time' <<<"$status" | cut -c1-10)"
printf '  %-20s %-34s %s\n' ROOM "NEEDS" "LICENSED"
row "Quantum PKI" edition                         # ML-DSA PKI; CA key export is Ent
row "Crypto agility" edition                      # transit/keys/:name/algorithm, ml-dsa, hybrid
row "Format-preserving" "Transform Secrets Engine" # FF1 + rewrap (ADP)
row "Lifecycle" edition
row "Public CA (opt.)" "PKI External CA Secrets Engine"
exit "$missing"
