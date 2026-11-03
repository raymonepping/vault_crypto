#!/bin/bash
# compose/identity/keycloak/setup_keycloak.sh — from Project Durin.
# Idempotent realm / federation / client setup for vault_crypto.
#
#   realm    vcry
#   LDAP     vcry.local, read-only federation
#            group mapper  → `groups` claim (vcry-viewers, vcry-pki-operators,
#                            vcry-key-custodians, vcry-data-stewards)
#   clients  vcry-console  confidential, Authorization Code + PKCE (the console's BFF)
#            vcry-cli      public, direct access grants: LOCAL LAB ONLY, for
#                          scripted authZ tests (scripts/identity-verify.sh, api-test)
#   claims   groups, aud += vcry-console (Vault's jwt role binds that audience)
#
# Vault decides what a person may do from the groups claim; Keycloak holds no
# roles of its own.
#
# Secrets are Vault-sourced (identity-secrets-init → /run/secrets). Nothing
# secret is printed.
set -euo pipefail

KC=/opt/keycloak/bin/kcadm.sh
KC_URL="${KC_INTERNAL_URL:-http://keycloak:8080}"
REALM=vcry
BACKEND_CLIENT=vcry-console
CLI_CLIENT=vcry-cli
AUDIENCE=vcry-console
LDAP_BASE_DN="dc=vcry,dc=local"

SECRETS="${IDENTITY_SECRETS_DIR:-/run/secrets}"
KEYCLOAK_ADMIN_PASSWORD="$(cat "$SECRETS/keycloak-admin-password")"
LDAP_ADMIN_PASSWORD="$(cat "$SECRETS/ldap-admin-password")"
OIDC_CLIENT_SECRET="$(cat "$SECRETS/console-client-secret")"

echo "Waiting for Keycloak at ${KC_URL}..."
attempt=0
until "$KC" config credentials --server "$KC_URL" --realm master \
  --user "${KEYCLOAK_ADMIN:-admin}" --password "$KEYCLOAK_ADMIN_PASSWORD" 2>/tmp/kcadm-login.err; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 40 ]; then
    echo "Keycloak did not become ready after $((attempt * 3))s:" >&2
    cat /tmp/kcadm-login.err >&2
    exit 1
  fi
  sleep 3
done

# ── helpers ────────────────────────────────────────────────────────────────
first_id() {
  grep -m1 '"id" *:' | sed -E 's/.*"id" *: *"([^"]*)".*/\1/'
  return 0
}

get_component_id() {
  "$KC" get components -r "$REALM" -q "name=$1" --fields id 2>/dev/null | first_id
}

get_client_uuid() {
  "$KC" get clients -r "$REALM" -q clientId="$1" --fields id 2>/dev/null | first_id
}

mapper_exists() { # client_uuid mapper_name
  "$KC" get "clients/$1/protocol-mappers/models" -r "$REALM" 2>/dev/null | grep -q "\"name\" *: *\"$2\""
}

# ── realm ──────────────────────────────────────────────────────────────────
ensure_realm() {
  if "$KC" get "realms/$REALM" >/dev/null 2>&1; then
    echo "  = realm exists: $REALM"
  else
    "$KC" create realms -s realm="$REALM" -s enabled=true -s sslRequired=NONE \
      -s accessTokenLifespan=300 -s ssoSessionIdleTimeout=3600 -s ssoSessionMaxLifespan=36000
    echo "  + realm created: $REALM"
  fi
}

# ── LDAP federation + mappers ──────────────────────────────────────────────
ensure_ldap_federation() {
  local id
  id=$(get_component_id vcry-ldap)
  if [ -n "$id" ]; then
    echo "  = LDAP federation exists: $id"
    # Keep the bind credential in step with Vault (rotation-safe).
    "$KC" update "components/$id" -r "$REALM" -s "config.bindCredential=[\"${LDAP_ADMIN_PASSWORD}\"]" >/dev/null
  else
    id=$("$KC" create components -r "$REALM" -i \
      -s name=vcry-ldap \
      -s providerId=ldap \
      -s providerType=org.keycloak.storage.UserStorageProvider \
      -s 'config.enabled=["true"]' \
      -s 'config.vendor=["other"]' \
      -s 'config.usernameLDAPAttribute=["uid"]' \
      -s 'config.rdnLDAPAttribute=["uid"]' \
      -s 'config.uuidLDAPAttribute=["entryUUID"]' \
      -s 'config.userObjectClasses=["inetOrgPerson, organizationalPerson"]' \
      -s 'config.connectionUrl=["ldap://openldap:389"]' \
      -s "config.usersDn=[\"ou=people,${LDAP_BASE_DN}\"]" \
      -s "config.bindDn=[\"cn=admin,${LDAP_BASE_DN}\"]" \
      -s "config.bindCredential=[\"${LDAP_ADMIN_PASSWORD}\"]" \
      -s 'config.editMode=["READ_ONLY"]' \
      -s 'config.syncRegistrations=["false"]' \
      -s 'config.pagination=["true"]' \
      -s 'config.importEnabled=["true"]' \
      -s 'config.trustEmail=["true"]')
    echo "  + LDAP federation created: $id"
  fi

  if [ -n "$(get_component_id vcry-groups)" ]; then
    echo "  = group mapper exists"
  else
    "$KC" create components -r "$REALM" \
      -s name=vcry-groups \
      -s providerId=group-ldap-mapper \
      -s providerType=org.keycloak.storage.ldap.mappers.LDAPStorageMapper \
      -s parentId="$id" \
      -s "config.\"groups.dn\"=[\"ou=groups,${LDAP_BASE_DN}\"]" \
      -s 'config."group.name.ldap.attribute"=["cn"]' \
      -s 'config."group.object.classes"=["groupOfNames"]' \
      -s 'config."membership.ldap.attribute"=["member"]' \
      -s 'config."membership.attribute.type"=["DN"]' \
      -s 'config.mode=["READ_ONLY"]' \
      -s 'config."preserve.group.inheritance"=["false"]' \
      -s 'config."ignore.missing.groups"=["false"]'
    echo "  + group mapper created"
  fi

  # Keycloak's default "first name" mapper reads cn (the full name), which
  # made the name claim "Olga Operator Operator". givenName is the first name.
  local fn
  fn=$("$KC" get components -r "$REALM" -q parent="$id" -q name="first name" --fields id 2>/dev/null | first_id)
  if [ -n "$fn" ]; then
    "$KC" update "components/$fn" -r "$REALM" -s 'config."ldap.attribute"=["givenName"]' >/dev/null &&
      echo "  = first name mapper reads givenName"
  fi

  echo "  -> triggering full LDAP sync"
  "$KC" create "user-storage/${id}/sync?action=triggerFullSync" -r "$REALM" -s x=1 >/dev/null 2>&1 ||
    echo "  ! full sync request did not confirm (non-fatal)"
}

# ── clients ────────────────────────────────────────────────────────────────
ensure_backend_client() {
  local uuid redirect post_logout
  uuid=$(get_client_uuid "$BACKEND_CLIENT")
  redirect="${VCRY_CONSOLE_URL:-https://localhost:13501}/auth/callback"
  post_logout="${VCRY_CONSOLE_URL:-https://localhost:13501}/"
  if [ -n "$uuid" ]; then
    echo "  = client exists: $BACKEND_CLIENT" >&2
  else
    "$KC" create clients -r "$REALM" \
      -s clientId="$BACKEND_CLIENT" \
      -s protocol=openid-connect \
      -s publicClient=false \
      -s standardFlowEnabled=true \
      -s implicitFlowEnabled=false \
      -s directAccessGrantsEnabled=false \
      -s serviceAccountsEnabled=false \
      -s 'attributes."pkce.code.challenge.method"=S256' \
      -s "redirectUris=[\"${redirect}\"]" \
      -s webOrigins='[]' >&2
    uuid=$(get_client_uuid "$BACKEND_CLIENT")
    echo "  + client created: $BACKEND_CLIENT" >&2
  fi
  # The secret is a property of the client (PUT clients/<id>); the
  # clients/<id>/client-secret sub-resource only regenerates a random one.
  if "$KC" update "clients/$uuid" -r "$REALM" -s "secret=$OIDC_CLIENT_SECRET" >/dev/null; then
    echo "  = client secret set from Vault (kv/vcry/identity/console-client-secret)" >&2
  else
    echo "  ! could not set the client secret for $BACKEND_CLIENT" >&2
    exit 1
  fi
  "$KC" update "clients/$uuid" -r "$REALM" \
    -s "attributes.\"post.logout.redirect.uris\"=${post_logout}" >/dev/null 2>&1
  echo "$uuid"
}

ensure_cli_client() {
  local uuid
  uuid=$(get_client_uuid "$CLI_CLIENT")
  if [ -n "$uuid" ]; then
    echo "  = client exists: $CLI_CLIENT (local lab only)" >&2
  else
    "$KC" create clients -r "$REALM" \
      -s clientId="$CLI_CLIENT" \
      -s protocol=openid-connect \
      -s publicClient=true \
      -s standardFlowEnabled=false \
      -s implicitFlowEnabled=false \
      -s directAccessGrantsEnabled=true \
      -s serviceAccountsEnabled=false \
      -s 'attributes."description"="Local lab only: scripted authZ tests (password grant). Remove outside the lab."' >&2
    uuid=$(get_client_uuid "$CLI_CLIENT")
    echo "  + client created: $CLI_CLIENT (public, direct access grants — local lab only)" >&2
  fi
  echo "$uuid"
}

ensure_claim_mappers() { # client_uuid client_label
  local uuid="$1"
  if mapper_exists "$uuid" groups; then echo "  = $2: groups claim"; else
    "$KC" create "clients/$uuid/protocol-mappers/models" -r "$REALM" \
      -s name=groups -s protocol=openid-connect -s protocolMapper=oidc-group-membership-mapper \
      -s 'config."full.path"=false' -s 'config."id.token.claim"=true' \
      -s 'config."access.token.claim"=true' -s 'config."userinfo.token.claim"=true' \
      -s 'config."claim.name"=groups'
    echo "  + $2: groups claim"
  fi
  if mapper_exists "$uuid" vcry-console-audience; then echo "  = $2: audience $AUDIENCE"; else
    "$KC" create "clients/$uuid/protocol-mappers/models" -r "$REALM" \
      -s name=vcry-console-audience -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper \
      -s "config.\"included.client.audience\"=$AUDIENCE" \
      -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false'
    echo "  + $2: audience $AUDIENCE"
  fi
}

# ── main ───────────────────────────────────────────────────────────────────
echo "-> realm"
ensure_realm

echo "-> LDAP federation + mappers"
ensure_ldap_federation

echo "-> clients"
BACKEND_UUID=$(ensure_backend_client | tail -1)
CLI_UUID=$(ensure_cli_client | tail -1)

echo "-> claim mappers"
ensure_claim_mappers "$BACKEND_UUID" "$BACKEND_CLIENT"
ensure_claim_mappers "$CLI_UUID" "$CLI_CLIENT"

echo
echo "================================================================"
echo "Keycloak realm '$REALM' ready."
echo "  Console client     : $BACKEND_CLIENT (secret in Vault KV)"
echo "  Test client        : $CLI_CLIENT (local lab only)"
echo "  Issuer             : see /realms/$REALM/.well-known/openid-configuration"
echo "  Verify             : make identity-verify"
echo "================================================================"
