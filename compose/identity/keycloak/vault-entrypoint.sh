#!/bin/sh
# compose/identity/keycloak/vault-entrypoint.sh — from Project Durin
#
# keycloak/keycloak:26.x has no _FILE support for the bootstrap admin
# password (confirmed in Editors Factory). Read the Vault-sourced value that
# identity-secrets-init rendered, export it under KC_BOOTSTRAP_ADMIN_*, then
# exec the real Keycloak launcher.
set -eu

password_file="${IDENTITY_SECRETS_DIR:-/run/secrets}/keycloak-admin-password"
attempt=0
until [ -s "$password_file" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -ge 30 ] && { echo "[vault-entrypoint] $password_file never appeared" >&2; exit 1; }
  sleep 2
done

KC_BOOTSTRAP_ADMIN_USERNAME="${KEYCLOAK_ADMIN:-admin}"
KC_BOOTSTRAP_ADMIN_PASSWORD="$(cat "$password_file")"
export KC_BOOTSTRAP_ADMIN_USERNAME KC_BOOTSTRAP_ADMIN_PASSWORD
echo "[vault-entrypoint] bootstrap admin credentials exported (Vault-sourced), starting Keycloak"
exec /opt/keycloak/bin/kc.sh "$@"
