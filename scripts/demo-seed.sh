#!/usr/bin/env bash
# scripts/demo-seed.sh [--reset] — the runtime state of the demo rooms.
#
# Terraform owns the configuration (mounts, CA chains, roles, transform). What
# the demo itself changes lives here, so `make tf-plan-all` stays clean after
# a demo (decision D7):
#
#   transit/keys/orders-signing   ecdsa-p256 at v1; the UI rotates it to
#                                 ml-dsa (65) and then hybrid
#   transit/keys/ledger-data      aes128-gcm96 at v1; the UI rotates it to
#                                 aes256-gcm96 and chacha20-poly1305
#   pki-pqc-next/*                empty; `make pki-move` imports the wrapped
#                                 ML-DSA issuing key into it
#
# Default: create-only, writes nothing that exists. --reset puts every room
# back to its starting state (type RESET, or RESET=yes for scripts).
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

vault_node vault-1
vault_root vault
export VAULT_ADDR VAULT_TOKEN VAULT_CACERT
log() { echo "[demo-seed] $*"; }

key_exists() { vault read "transit/keys/$1" >/dev/null 2>&1; }

create_keys() {
  if key_exists orders-signing; then
    log "transit/keys/orders-signing exists (v$(vault read -field=latest_version transit/keys/orders-signing)) — kept"
  else
    vault write -f transit/keys/orders-signing type=ecdsa-p256 >/dev/null
    log "transit/keys/orders-signing created: ecdsa-p256"
  fi
  if key_exists ledger-data; then
    log "transit/keys/ledger-data exists (v$(vault read -field=latest_version transit/keys/ledger-data)) — kept"
  else
    vault write -f transit/keys/ledger-data type=aes128-gcm96 >/dev/null
    log "transit/keys/ledger-data created: aes128-gcm96"
  fi
}

delete_key() {
  key_exists "$1" || return 0
  vault write "transit/keys/$1/config" deletion_allowed=true >/dev/null
  vault delete "transit/keys/$1" >/dev/null
  log "transit/keys/$1 deleted"
}

# Empty pki-pqc-next again: its issuers, keys, role and export keys. The
# source issuer on pki-pqc-int keeps its "private key exported" warning: Vault
# records that forever, and the demo does not hide it.
reset_pki_next() {
  local id out
  # Quiet: Vault warns about deleting the default issuer/key, which is the point.
  del() {
    out=$(vault delete "$1" 2>&1) || {
      echo "$out" >&2
      return 1
    }
    log "$2 deleted"
  }
  if vault read pki-pqc-next/roles/service >/dev/null 2>&1; then del pki-pqc-next/roles/service "pki-pqc-next role service"; fi
  for id in $(vault_list_json pki-pqc-next/issuers | jq -r '.[]'); do
    del "pki-pqc-next/issuer/$id" "pki-pqc-next issuer $id"
  done
  for id in $(vault_list_json pki-pqc-next/keys | jq -r '.[]'); do
    del "pki-pqc-next/key/$id" "pki-pqc-next key $id"
  done
  for id in $(vault_list_json pki-pqc-next/export | jq -r '.[]'); do
    del "pki-pqc-next/export/$id" "pki-pqc-next export key $id"
  done
}

case "${1:-}" in
"") create_keys ;;
--reset)
  if [ "${RESET:-}" != yes ]; then
    printf 'This deletes and recreates the two demo Transit keys (every ciphertext and\nsignature made with them becomes undecryptable/unverifiable) and empties\npki-pqc-next. Type RESET: '
    read -r answer
    [ "$answer" = RESET ] || {
      echo "Aborted."
      exit 1
    }
  fi
  delete_key orders-signing
  delete_key ledger-data
  reset_pki_next
  create_keys
  log "reset done: every room is back at its starting state"
  ;;
*)
  echo "Usage: $0 [--reset]" >&2
  exit 64
  ;;
esac
