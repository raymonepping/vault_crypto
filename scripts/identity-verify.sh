#!/usr/bin/env bash
# scripts/identity-verify.sh — who may do what, end to end. Read-only.
#
# Per persona: Keycloak issues a token with the right groups and audience;
# Vault's jwt role turns it into a token with the right policies; LDAP login
# to Vault gives the same; Vault answers the capability questions the rooms
# depend on, allowed AND refused. Passwords come from Vault KV and are never
# printed.
set -uo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
set +e
cd "$VCRY_ROOT"

pass=0; fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail + 1)); }
KC="http://127.0.0.1:$(vcry_conf VCRY_PORT_KEYCLOAK)"
vault_node vault-1
export VAULT_ADDR VAULT_CACERT

kc_token() { # persona → access token (lab-only client vcry-cli, password grant)
  curl -s -X POST "$KC/realms/vcry/protocol/openid-connect/token" -d grant_type=password -d client_id=vcry-cli \
    -d username="$1" --data-urlencode "password=$(./scripts/identity-secrets.sh --print "$1")" -d scope=openid |
    jq -r '.access_token // empty'
}
claims() { node -e 'process.stdout.write(Buffer.from(process.argv[1].split(".")[1],"base64url").toString())' "$1"; }

# persona | expected groups (sorted, comma) | expected policies (sorted, comma)
PERSONAS="vera vcry-viewers vcry-viewer
piet vcry-pki-operators,vcry-viewers vcry-pki-operator,vcry-viewer
kees vcry-key-custodians,vcry-viewers vcry-key-custodian,vcry-viewer
dana vcry-data-stewards,vcry-viewers vcry-data-steward,vcry-viewer
olga vcry-data-stewards,vcry-key-custodians,vcry-pki-operators,vcry-viewers vcry-data-steward,vcry-key-custodian,vcry-pki-operator,vcry-viewer"

echo "directory and realm"
[ "$(vcry_container_state vcry-openldap)" = running ] && ok "vcry-openldap running" || bad "vcry-openldap running"
[ "$(vcry_container_state vcry-keycloak)" = running ] && ok "vcry-keycloak running" || bad "vcry-keycloak running"
curl -sf "$KC/realms/vcry/.well-known/openid-configuration" | jq -e '.issuer == "http://localhost:13502/realms/vcry"' >/dev/null &&
  ok "realm vcry publishes its issuer" || bad "realm vcry publishes its issuer"

declare -A VTOKEN
echo "people"
while read -r who groups policies; do
  t=$(kc_token "$who")
  if [ -z "$t" ]; then bad "$who: Keycloak refused the login"; continue; fi
  c=$(claims "$t")
  got=$(jq -r '.groups | sort | join(",")' <<<"$c")
  [ "$got" = "$groups" ] && ok "$who: Keycloak groups $got" || bad "$who: Keycloak groups $got, want $groups"
  jq -e '.aud | index("vcry-console")' <<<"$c" >/dev/null && ok "$who: audience vcry-console" || bad "$who: audience"
  login=$(vault write -format=json auth/jwt/login role=console jwt="$t" 2>&1)
  vp=$(jq -r '.auth.identity_policies // [] | sort | join(",")' <<<"$login" 2>/dev/null)
  [ "$vp" = "$policies" ] && ok "$who: Vault jwt login, policies $vp" || bad "$who: Vault jwt policies '$vp', want $policies"
  VTOKEN[$who]=$(jq -r '.auth.client_token // empty' <<<"$login" 2>/dev/null)
  lp=$(vault write -format=json "auth/ldap/login/$who" password="$(./scripts/identity-secrets.sh --print "$who")" 2>/dev/null |
    jq -r '.auth.policies // [] | map(select(. != "default")) | sort | join(",")')
  [ "$lp" = "$policies" ] && ok "$who: Vault LDAP login, same policies" || bad "$who: Vault LDAP policies '$lp', want $policies"
done <<<"$PERSONAS"

echo "authority (Vault's own answer, sys/capabilities-self)"
cap() { VAULT_TOKEN="${VTOKEN[$1]}" vault token capabilities "$2" 2>/dev/null; }
expect() { # persona path allowed|deny description
  local got; got=$(cap "$1" "$2")
  if [ "$3" = deny ]; then
    [ "$got" = deny ] && ok "$1 refused: $4" || bad "$1 should be refused: $4 (got $got)"
  else
    [ "$got" != deny ] && [ -n "$got" ] && ok "$1 may: $4" || bad "$1 should be allowed: $4 (got ${got:-nothing})"
  fi
}
expect vera pki-pqc-int/certs allowed "list the inventory"
expect vera transit/verify/orders-signing allowed "verify signatures"
expect vera pki-pqc-int/issue/service deny "issue a certificate"
expect vera transit/keys/orders-signing/algorithm deny "rotate an algorithm"
expect vera transform/decode/payments deny "decode FF1 values"
expect piet pki-pqc-int/issue/service allowed "issue an ML-DSA certificate"
expect piet pki-classic-int/revoke allowed "revoke"
expect piet transit/keys/orders-signing/algorithm deny "rotate an algorithm"
expect kees transit/keys/orders-signing/algorithm allowed "rotate an algorithm"
expect kees transit/rewrap/ledger-data allowed "rewrap the ledger"
expect kees transform/decode/payments deny "decode FF1 values"
expect dana transform/decode/payments allowed "decode FF1 values"
expect dana pki-pqc-int/issue/service deny "issue a certificate"
expect olga pki-pqc-next/issue/service allowed "issue from the moved key"
expect olga pki-pqc-int/keys/x/export deny "export a CA key (operator only: make pki-move)"
expect olga transit/export/signing-key/orders-signing deny "export a Transit key"

for who in "${!VTOKEN[@]}"; do VAULT_TOKEN="${VTOKEN[$who]}" vault token revoke -self >/dev/null 2>&1; done
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
