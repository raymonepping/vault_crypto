#!/usr/bin/env bash
# scripts/rotator-bootstrap.sh [seal|app …] — deliver each plane's rotator
# credential (default: both), mode 0600:
#
#   seal  .secrets/vault/seal-rotator/  role seal-rotator on vault-s
#   app   .secrets/vault/rotator/       role crypto-rotator on vault-1
#
# These are the only machine credentials a human hands over. Everything else
# is issued and rotated by machines. Idempotent: keeps a secret-id Vault accepts.
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

deliver() {
  local role=$3 dir=$4 out
  vault_node "$1"
  vault_root "$2"
  mkdir -p "$dir"
  chmod 700 "$dir"
  vault read -field=role_id "auth/approle/role/$role/role-id" >"$dir/role-id.tmp"
  cat "$dir/role-id.tmp" >"$dir/role-id"
  rm -f "$dir/role-id.tmp"
  if [ -s "$dir/secret-id" ] &&
    out=$(vault write -format=json "auth/approle/role/$role/secret-id/lookup" secret_id="$(cat "$dir/secret-id")" 2>/dev/null) &&
    jq -e '.data.secret_id_accessor' <<<"$out" >/dev/null 2>&1; then
    echo "rotator-bootstrap: $role secret-id is still valid — kept"
  else
    vault write -field=secret_id -f "auth/approle/role/$role/secret-id" metadata=consumer="$role" >"$dir/secret-id.tmp"
    cat "$dir/secret-id.tmp" >"$dir/secret-id"
    rm -f "$dir/secret-id.tmp"
    echo "rotator-bootstrap: $role secret-id issued (${dir#"$VCRY_ROOT"/})"
  fi
  unset VAULT_TOKEN
}

planes=${*:-seal app}
for plane in $planes; do
  case "$plane" in
  seal) deliver vault-s seal seal-rotator "$VCRY_STATE/seal-rotator" ;;
  app)  deliver vault-1 vault crypto-rotator "$VCRY_STATE/rotator" ;;
  *) echo "rotator-bootstrap: unknown plane '$plane' (seal|app)" >&2; exit 64 ;;
  esac
done
