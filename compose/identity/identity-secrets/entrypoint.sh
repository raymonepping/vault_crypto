#!/bin/sh
# compose/identity/identity-secrets/entrypoint.sh — from Project Durin.
#
# One-shot: AppRole login → read the identity secrets from Vault KV → render
# them to the shared identity-secrets volume → revoke its own token → exit.
# openldap, keycloak and their bootstrap containers mount the volume
# read-only and never talk to Vault themselves.
set -eu

ROLE_ID="$(cat /approle/role-id)"
SECRET_ID="$(cat /approle/secret-id)"

echo "[identity-secrets-init] AppRole login as identity-secrets..."
attempt=0
until VAULT_TOKEN=$(vault write -field=token auth/approle/login \
  role_id="$ROLE_ID" secret_id="$SECRET_ID" 2>/tmp/login.err); do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 15 ]; then
    echo "[identity-secrets-init] AppRole login failed after $((attempt * 2))s:" >&2
    cat /tmp/login.err >&2
    exit 1
  fi
  sleep 2
done
export VAULT_TOKEN

out=/run/secrets
mkdir -p "$out/users"
for key in ldap-admin-password keycloak-admin-password console-client-secret; do
  vault kv get -mount=kv -field=value "vcry/identity/$key" >"$out/$key"
done
count=0
for u in $(vault kv list -mount=kv -format=json vcry/identity/users | tr -d '[]", ' | tr '\n' ' '); do
  vault kv get -mount=kv -field=value "vcry/identity/users/$u" >"$out/users/$u"
  count=$((count + 1))
done
# Readable by the non-root keycloak user (uid 1000) and the osixia containers.
chmod 0755 "$out" "$out/users"
chmod 0644 "$out"/*-password "$out/console-client-secret" "$out"/users/*

vault token revoke -self >/dev/null 2>&1 || true
echo "[identity-secrets-init] rendered 3 platform secrets + $count persona passwords; token revoked"
