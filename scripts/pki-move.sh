#!/usr/bin/env bash
# scripts/pki-move.sh [--status] — move the ML-DSA issuing key from
# pki-pqc-int to pki-pqc-next without it ever existing in plaintext outside
# Vault (Vault Enterprise 2.2 CA key export/import).
#
#   1. pki-pqc-next creates an ML-KEM-1024 export key pair; only its public
#      half leaves Vault.
#   2. pki-pqc-int exports its issuing key wrapped to that public key
#      (needs sudo on the path: an operator action, never the API's).
#   3. pki-pqc-next imports the wrapped blob with wrapped_key +
#      export_key_hmac, then the intermediate's certificate, which Vault
#      maps to the imported key.
#   4. A role `service` on pki-pqc-next proves the moved key issues.
#
# The wrapped blob lives in a shell variable for the seconds between export
# and import and is never written to disk or printed. Idempotent: does nothing
# when pki-pqc-next already holds the key. Undo: make demo-reset.
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

vault_node vault-1
vault_root vault
export VAULT_ADDR VAULT_TOKEN VAULT_CACERT
log() { echo "[pki-move] $*"; }

src_key=$(vault read -field=key_id pki-pqc-int/issuer/default)
src_type=$(vault read -format=json "pki-pqc-int/key/$src_key" | jq -r '"\(.data.key_type) \(.data.parameter_set // "")"')
moved=$(vault_list_json pki-pqc-next/keys | jq -r length)

if [ "${1:-}" = --status ]; then
  echo "source: pki-pqc-int key $src_key ($src_type)"
  vault read -format=json pki-pqc-int/issuer/default | jq -r '.warnings // [] | .[] | "  warning: " + .'
  if [ "$moved" -gt 0 ]; then
    vault_list_json pki-pqc-next/keys | jq -r '.[]' | while read -r k; do
      vault read -format=json "pki-pqc-next/key/$k" | jq -r '"target: pki-pqc-next key \(.data.key_id) \(.data.key_name) (\(.data.key_type) \(.data.parameter_set // ""))"'
    done
  else
    echo "target: pki-pqc-next is empty (make pki-move)"
  fi
  exit 0
fi

if [ "$moved" -gt 0 ]; then
  log "pki-pqc-next already holds a key — nothing to do (make demo-reset to start over)"
  exec "$0" --status
fi

log "source key $src_key on pki-pqc-int ($src_type)"
ek=$(vault write -format=json pki-pqc-next/export key_type=ml-kem-1024 name=pqc-move)
ek_id=$(jq -r .data.export_key_uuid <<<"$ek")
pub=$(jq -r .data.public_key <<<"$ek")
log "1. pki-pqc-next export key $ek_id (ml-kem-1024): public half only"

exp=$(vault write -format=json "pki-pqc-int/keys/$src_key/export" public_key="$pub")
hmac=$(jq -r .data.export_key_hmac <<<"$exp")
log "2. exported wrapped ($(jq -r '.data.wrapped_key | length' <<<"$exp") chars), $hmac"

imp=$(vault write -format=json pki-pqc-next/keys/import wrapped_key="$(jq -r .data.wrapped_key <<<"$exp")" \
  export_key_hmac="$hmac" key_name=pqc-int-moved)
unset exp
new_key=$(jq -r .data.key_id <<<"$imp")
log "3. imported as key $new_key ($(jq -r '"\(.data.key_type) \(.data.parameter_set)"' <<<"$imp"))"

cert=$(vault read -field=certificate pki-pqc-int/issuer/default)
issuer=$(vault write -format=json pki-pqc-next/issuers/import/cert pem_bundle="$cert" |
  jq -r --arg k "$new_key" '.data.mapping | to_entries[] | select(.value == $k) | .key')
[ -n "$issuer" ] || {
  echo "pki-move: the intermediate's certificate did not map to the imported key" >&2
  exit 1
}
vault write "pki-pqc-next/issuer/$issuer" issuer_name=pqc-int-moved >/dev/null
vault write pki-pqc-next/config/issuers default="$issuer" >/dev/null
log "   issuer $issuer now signs with the moved key"

vault write pki-pqc-next/roles/service issuer_ref="$issuer" allowed_domains=lab.local allow_subdomains=true \
  key_type=ml-dsa parameter_set=ml-dsa-44 ttl=3600 max_ttl=86400 organization="Vault Crypto Lab" ou=post-quantum-moved >/dev/null
serial=$(vault write -field=serial_number pki-pqc-next/issue/service common_name=moved.lab.local ttl=5m)
log "4. pki-pqc-next issued $serial with the moved key"
"$0" --status
