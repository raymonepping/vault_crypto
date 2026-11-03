#!/usr/bin/env bash
# scripts/identity-secrets.sh — the identity stack's secrets, in Vault KV.
#
#   identity-secrets.sh                  create what is missing (never overwrites),
#                                        deliver AppRole identity-secrets to
#                                        .secrets/vault/identity/
#   identity-secrets.sh --rotate-user U  new password for persona U (then
#                                        make identity-bootstrap to apply it)
#   identity-secrets.sh --copy U         put U's password on the macOS clipboard;
#                                        nothing is printed
#   identity-secrets.sh --print U        U's password on stdout, for test
#                                        tooling only (e2e, identity-verify)
#
# Paths: kv/vcry/identity/{ldap-admin-password,keycloak-admin-password,
# console-client-secret,users/<uid>}.
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

PERSONAS="vera piet kees dana olga"
vault_node vault-1
vault_root vault
export VAULT_ADDR VAULT_TOKEN VAULT_CACERT
gen() { openssl rand -base64 33 | tr -d '/+=\n' | cut -c1-28; }
exists() { vault kv get -mount=kv "vcry/identity/$1" >/dev/null 2>&1; }
put() { vault kv put -mount=kv "vcry/identity/$1" value="$2" >/dev/null; }
user_ok() {
  case " $PERSONAS " in *" $1 "*) return 0 ;; esac
  echo "identity-secrets: unknown persona '$1' (one of: $PERSONAS)" >&2
  exit 64
}

case "${1:-}" in
--rotate-user)
  user_ok "${2:-}"
  put "users/$2" "$(gen)"
  echo "identity-secrets: new password for $2 in Vault; run make identity-bootstrap to apply it"
  exit 0
  ;;
--copy)
  user_ok "${2:-}"
  vault kv get -mount=kv -field=value "vcry/identity/users/$2" | tr -d '\n' | pbcopy
  echo "identity-secrets: the password for $2 is on the clipboard (log in at the console with username $2)"
  exit 0
  ;;
--print)
  user_ok "${2:-}"
  vault kv get -mount=kv -field=value "vcry/identity/users/$2"
  exit 0
  ;;
"") ;;
*)
  echo "Usage: $0 [--rotate-user U | --copy U | --print U]" >&2
  exit 64
  ;;
esac

created=0
for key in ldap-admin-password keycloak-admin-password console-client-secret; do
  exists "$key" || {
    put "$key" "$(gen)"
    created=$((created + 1))
  }
done
for u in $PERSONAS; do
  exists "users/$u" || {
    put "users/$u" "$(gen)"
    created=$((created + 1))
  }
done
echo "identity-secrets: $created secret(s) created in kv/vcry/identity (existing ones kept)"

# The init container's credential: role-id + a non-expiring, CIDR-bound secret-id.
dir="$VCRY_STATE/identity"
mkdir -p "$dir"
chmod 700 "$dir"
vault read -field=role_id auth/approle/role/identity-secrets/role-id >"$dir/role-id"
if [ -s "$dir/secret-id" ] &&
  vault write -format=json auth/approle/role/identity-secrets/secret-id/lookup secret_id="$(cat "$dir/secret-id")" >/dev/null 2>&1; then
  echo "identity-secrets: AppRole identity-secrets credential still valid, kept"
else
  vault write -field=secret_id -f auth/approle/role/identity-secrets/secret-id >"$dir/secret-id.tmp"
  cat "$dir/secret-id.tmp" >"$dir/secret-id"
  rm -f "$dir/secret-id.tmp"
  echo "identity-secrets: AppRole identity-secrets credential delivered to .secrets/vault/identity/"
fi
# Rootless Podman: root in the init container is this host user, so 0600 reads.
chmod 600 "$dir/role-id" "$dir/secret-id"
