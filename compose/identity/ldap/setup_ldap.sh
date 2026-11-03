#!/usr/bin/env bash
# compose/identity/ldap/setup_ldap.sh
# Idempotent per-entry loader for bootstrap.ldif.
# Runs inside the ldap-bootstrap container (profiles: ["init"]).
# LDAP_BASE_DN / LDAP_HOST from compose environment. The admin password and
# every user password are Vault-sourced , rendered by
# identity-secrets-init onto /run/secrets — never in .env or the LDIF.
set -euo pipefail

SECRETS="${IDENTITY_SECRETS_DIR:-/run/secrets}"
LDAP_ADMIN_PASSWORD="$(cat "${LDAP_ADMIN_PASSWORD_FILE:-$SECRETS/ldap-admin-password}")"

LDAP_HOST="${LDAP_HOST:-openldap}"
BASE_DN="${LDAP_BASE_DN:-dc=vcry,dc=local}"
BIND_DN="cn=admin,${BASE_DN}"
LDIF="/bootstrap/bootstrap.ldif"

echo "Waiting for ${LDAP_HOST}..."
for _ in $(seq 1 30); do
  ldapsearch -x -H "ldap://${LDAP_HOST}" -D "$BIND_DN" -w "$LDAP_ADMIN_PASSWORD" -b "$BASE_DN" -s base >/dev/null 2>&1 && break
  sleep 2
done

added=0
skipped=0
failed=0

entry=""
apply_entry() {
  [ -z "$1" ] && return 0
  local dn
  dn="$(printf '%s\n' "$1" | awk -F': ' '/^dn:/{print $2; exit}')"
  [ -z "$dn" ] && return 0

  if ldapsearch -x -H "ldap://${LDAP_HOST}" -D "$BIND_DN" -w "$LDAP_ADMIN_PASSWORD" \
    -b "$dn" -s base >/dev/null 2>&1; then
    echo "  = exists: $dn"
    skipped=$((skipped + 1))
    return 0
  fi

  if printf '%s\n' "$1" | ldapadd -x -H "ldap://${LDAP_HOST}" -D "$BIND_DN" -w "$LDAP_ADMIN_PASSWORD" >/dev/null 2>&1; then
    echo "  + added: $dn"
    added=$((added + 1))
  else
    echo "  ! failed: $dn" >&2
    failed=$((failed + 1))
  fi
}

while IFS= read -r line; do
  if [ -z "$line" ]; then
    apply_entry "$entry"
    entry=""
  elif [[ "$line" == \#* ]]; then
    continue
  else
    entry="${entry}${line}"$'\n'
  fi
done <"$LDIF"
apply_entry "$entry"

echo
echo "LDAP fixture: ${added} added, ${skipped} already present, ${failed} failed"
[ "$failed" -eq 0 ] || exit 1

# Passwords: always (re)applied from Vault, so --rotate-user takes effect on the
# next bootstrap. ldappasswd hashes server-side (SSHA); nothing is printed.
echo
pw_set=0
for file in "$SECRETS"/users/*; do
  uid="$(basename "$file")"
  dn="uid=${uid},ou=people,${BASE_DN}"
  if ldappasswd -x -H "ldap://${LDAP_HOST}" -D "$BIND_DN" -w "$LDAP_ADMIN_PASSWORD" \
       -s "$(cat "$file")" "$dn" >/dev/null 2>&1; then
    echo "  * password set from Vault: $uid"
    pw_set=$((pw_set + 1))
  else
    echo "  ! password NOT set: $uid" >&2
    failed=$((failed + 1))
  fi
done
[ "$failed" -eq 0 ] || exit 1
echo "LDAP passwords: ${pw_set} set from Vault KV (kv/vcry/identity/users/*)"
echo "Copy one to the clipboard: make identity-copy-password U=<uid>"
