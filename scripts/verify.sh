#!/usr/bin/env bash
# scripts/verify.sh [section…] — end-to-end checks of the running lab.
# Read-only apart from the short-lived certificates and scratch keys it creates
# and removes itself. Sections: podman vault crypto identity app rooms
# (default: all).
# The browser-level checks are Playwright's: make test-ui.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VCRY_ROOT"

pass=0; fail=0
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass + 1)); }
bad()   { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail + 1)); }
check() { local msg=$1; shift; if "$@" >/dev/null 2>&1; then ok "$msg"; else bad "$msg"; fi; }
healthy() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(podman container inspect "$1" --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] && return 0
    sleep 3
  done
  return 1
}

API="http://127.0.0.1:$(vcry_conf VCRY_PORT_API)"
WEB_PORT=$(vcry_conf VCRY_PORT_WEB)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

section_podman() {
  echo "podman"
  check "Podman machine answers" podman info
  check "network vcry-internal exists" podman network exists vcry-internal
  local arch
  arch=$(podman image inspect "$(vcry_conf VAULT_ENT_IMAGE)" --format '{{.Architecture}}' 2>/dev/null || echo "?")
  check "Vault Enterprise image is native ($arch, not emulated)" test "$arch" = "$(podman info --format '{{.Host.Arch}}')"
  arch=$(podman image inspect "$(vcry_conf VAULT_IMAGE)" --format '{{.Architecture}}' 2>/dev/null || echo "?")
  check "Vault Community image is native ($arch)" test "$arch" = "$(podman info --format '{{.Host.Arch}}')"
}

section_vault() {
  echo "vault"
  check "listener certificate chains to the lab CA" openssl verify -CAfile vault-tls/ca-chain.pem vault-tls/vault.crt
  check "vcry-vault-s healthy" healthy vcry-vault-s
  check "vcry-vault-1 healthy" healthy vcry-vault-1

  vault_node vault-s
  local s
  s=$(vault_json 2>/dev/null || echo '{}')
  check "vault-s initialized and unsealed" jq -e '.initialized and (.sealed | not)' <<<"$s"
  check "vault-s seal type is shamir" jq -e '.type == "shamir"' <<<"$s"
  check "vault-s is Community $(jq -r .version <<<"$s")" jq -e '(.version | test("\\+ent") | not) and (.version | startswith("2.2."))' <<<"$s"
  vault_root seal
  check "vault-s transit key autounseal exists" vault read transit/keys/autounseal
  check "vault-s audit device enabled" bash -c 'vault audit list -format=json | jq -e "has(\"file/\")"'
  unset VAULT_TOKEN

  vault_node vault-1
  s=$(vault_json 2>/dev/null || echo '{}')
  check "vault-1 initialized and unsealed" jq -e '.initialized and (.sealed | not)' <<<"$s"
  check "vault-1 seal type is transit (auto-unseal via vault-s)" jq -e '.type == "transit"' <<<"$s"
  check "vault-1 runs Vault Enterprise 2.2 ($(jq -r .version <<<"$s"))" jq -e '(.version | test("\\+ent")) and (.version | startswith("2.2."))' <<<"$s"
  check "vault-1 is the active node" bash -c 'curl -sf --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/sys/leader" | jq -e .is_self'
  vault_root vault
  check "vault-1 licence is valid" bash -c 'vault read -format=json sys/license/status | jq -e ".data.autoloaded.expiration_time"'
  check "licence has every feature the rooms need" ./scripts/license-features.sh
  check "vault-1 audit device enabled" bash -c 'vault audit list -format=json | jq -e "has(\"file/\")"'
  unset VAULT_TOKEN
  check "vault-1 runs on the seal agent's token" bash -c './scripts/seal-token-status.sh | grep -q "seal agent sink"'
}

section_crypto() {
  echo "crypto"
  vault_node vault-1
  vault_root vault
  local m
  for m in pki-classic-root pki-classic-int pki-pqc-root pki-pqc-int pki-pqc-next transit transform; do
    check "mount $m exists" bash -c "vault secrets list -format=json | jq -e 'has(\"$m/\")'"
  done
  curl -sf --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/pki-pqc-root/ca/pem" >"$TMP/pqc-root.pem" || true
  curl -sf --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/pki-pqc-int/ca/pem" >"$TMP/pqc-int.pem" || true
  check "PQC root is ML-DSA-87, self-signed" bash -c "openssl x509 -in '$TMP/pqc-root.pem' -noout -text | grep -q 'Signature Algorithm: ML-DSA-87'"
  check "PQC intermediate key is ML-DSA-65 and verifies against the root" bash -c \
    "openssl x509 -in '$TMP/pqc-int.pem' -noout -text | grep -q 'ML-DSA-65' && openssl verify -CAfile '$TMP/pqc-root.pem' '$TMP/pqc-int.pem'"
  check "PQC role issues ML-DSA-44 leaves" bash -c 'vault read -format=json pki-pqc-int/roles/service | jq -e ".data.key_type == \"ml-dsa\" and .data.parameter_set == \"ml-dsa-44\""'
  check "OCSP is off on the PQC intermediate, on for classic" bash -c \
    'vault read -format=json pki-pqc-int/config/crl | jq -e .data.ocsp_disable && vault read -format=json pki-classic-int/config/crl | jq -e ".data.ocsp_disable == false"'
  check "PQC CRL is published and ML-DSA-signed" bash -c "curl -sf --cacert '$VAULT_CACERT' '$VAULT_ADDR/v1/pki-pqc-int/crl/pem' | openssl crl -noout -text | grep -q 'ML-DSA-65'"
  check "demo key orders-signing exists (signing)" bash -c 'vault read -format=json transit/keys/orders-signing | jq -e ".data.supports_signing"'
  check "demo key ledger-data exists (encryption)" bash -c 'vault read -format=json transit/keys/ledger-data | jq -e ".data.supports_encryption"'
  check "every transformation is FF1" bash -c \
    'for t in ccn-legacy ccn-2026 iban-ff1 bsn-ff1; do vault read -format=json transform/transformations/fpe/$t | jq -e ".data.fpe_algorithm == \"ff1\"" >/dev/null || exit 1; done'
  unset VAULT_TOKEN
  check "Terraform roots have no pending changes" make --no-print-directory tf-plan-all
}

section_identity() {
  echo "identity"
  local c
  for c in vcry-seal-rotator vcry-seal-agent vcry-rotator vcry-vault-agent vcry-tls-agent; do check "$c healthy" healthy "$c"; done
  check "every rotator credential logs in and every agent token is valid" ./scripts/agents-status.sh
  check "the API has no VAULT_TOKEN in its environment" bash -c '! podman inspect vcry-api --format "{{range .Config.Env}}{{println .}}{{end}}" | grep -q "^VAULT_TOKEN="'
  check "the API cannot see the web server's key (web-tls not mounted)" bash -c '! podman inspect vcry-api --format "{{range .Mounts}}{{.Destination}} {{end}}" | grep -q nginx/tls'
  check "tls-agent's token never leaves the container (tmpfs sink)" bash -c '! podman inspect vcry-tls-agent --format "{{range .Mounts}}{{.Destination}} {{end}}" | grep -q "/vault/secrets"'
  # What the API's own token may not do, asked of Vault itself.
  check "API token: deny on pki-pqc-root/root/generate/internal" bash -c "[ \"\$(podman exec vcry-vault-agent sh -c 'VAULT_TOKEN=\$(cat /vault/secrets/token) vault token capabilities pki-pqc-root/root/generate/internal')\" = deny ]"
  check "API token: deny on CA key export (pki-pqc-int/keys/<key>/export)" bash -c "[ \"\$(podman exec vcry-vault-agent sh -c 'VAULT_TOKEN=\$(cat /vault/secrets/token) vault token capabilities pki-pqc-int/keys/x/export')\" = deny ]"
  check "API token: deny on transit/export and other keys" bash -c "[ \"\$(podman exec vcry-vault-agent sh -c 'VAULT_TOKEN=\$(cat /vault/secrets/token) vault token capabilities transit/export/signing-key/orders-signing')\" = deny ] && [ \"\$(podman exec vcry-vault-agent sh -c 'VAULT_TOKEN=\$(cat /vault/secrets/token) vault token capabilities transit/sign/other')\" = deny ]"
  check "API token: deny on every room action (since prompt 08)" bash -c "[ \"\$(podman exec vcry-vault-agent sh -c 'VAULT_TOKEN=\$(cat /vault/secrets/token) vault token capabilities transit/sign/orders-signing')\" = deny ]"
  check "API token: deny on deleting a demo key" bash -c "podman exec vcry-vault-agent sh -c 'VAULT_TOKEN=\$(cat /vault/secrets/token) vault token capabilities transit/keys/orders-signing' | grep -qv delete"
}

section_app() {
  echo "app"
  vault_node vault-1
  curl -sf --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/pki-classic-root/ca/pem" >"$TMP/root.pem" || true
  check "vcry-api healthy" healthy vcry-api
  check "vcry-web healthy" healthy vcry-web
  check "API /api/health: ok, both nodes unsealed, agent token present" bash -c "curl -sf '$API/api/health' | jq -e '.ok and (.seal.sealed|not) and (.vault.sealed|not) and .agent.tokenPresent and .vault.enterprise'"
  check "web UI certificate verifies against pki-classic-root for 'localhost'" bash -c \
    "openssl s_client -connect 127.0.0.1:$WEB_PORT -servername localhost -verify_hostname localhost -CAfile '$TMP/root.pem' -verify_return_error </dev/null 2>/dev/null | grep -q 'Verify return code: 0'"
  check "web UI certificate is classic ECDSA from role web (OU=web)" bash -c \
    "openssl s_client -connect 127.0.0.1:$WEB_PORT -servername localhost </dev/null 2>/dev/null | openssl x509 -noout -text | grep -q 'OU=web' "
  check "web UI serves index.html" bash -c "curl -sf --cacert '$TMP/root.pem' https://localhost:$WEB_PORT/ | grep -q '<div id=\"root\">'"
  # macOS curl has no --tlsv1.3; openssl asks for each version explicitly.
  check "web UI speaks TLS 1.3 and refuses TLS 1.2" bash -c \
    "openssl s_client -connect 127.0.0.1:$WEB_PORT -servername localhost -tls1_3 </dev/null 2>/dev/null | grep -q 'TLSv1.3' && ! openssl s_client -connect 127.0.0.1:$WEB_PORT -servername localhost -tls1_2 </dev/null >/dev/null 2>&1"
  check "web UI proxies /api to the API" bash -c "curl -sf --cacert '$TMP/root.pem' https://localhost:$WEB_PORT/api/capabilities | jq -e '.rooms | length == 4'"
  check "web UI proxies /auth to the API (sign-in redirects to Keycloak with PKCE)" bash -c "curl -s -o /dev/null -w '%{redirect_url}' --cacert '$TMP/root.pem' https://localhost:$WEB_PORT/auth/login | grep -q 'code_challenge_method=S256'"
}

section_identity_people() {
  echo "people (LDAP + Keycloak → Vault)"
  check "identity-verify: every persona's groups, policies and refusals" ./scripts/identity-verify.sh
  check "the API's own token holds no room authority (deny on pki-pqc-int/issue/service)" bash -c \
    "[ \"\$(podman exec vcry-vault-agent sh -c 'VAULT_TOKEN=\$(cat /vault/secrets/token) vault token capabilities pki-pqc-int/issue/service')\" = deny ]"
  check "rooms refuse a request without a person (401)" bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' '$API/api/pki/chains')\" = 401 ]"
}

# olga's Keycloak access token, for the rooms section.
olga_token() {
  curl -s -X POST "http://127.0.0.1:$(vcry_conf VCRY_PORT_KEYCLOAK)/realms/vcry/protocol/openid-connect/token" -d grant_type=password -d client_id=vcry-cli \
    -d username=olga --data-urlencode "password=$(./scripts/identity-secrets.sh --print olga)" -d scope=openid | jq -r '.access_token // empty'
}

section_rooms() {
  echo "rooms (through the API, as the UI calls it, signed in as olga)"
  local T; T=$(olga_token)
  export AUTHZ="authorization: Bearer $T"
  check "all four rooms available" bash -c "curl -sf '$API/api/capabilities' | jq -e '[.rooms[].available] | all'"
  check "a PQC leaf verifies under Node and OpenSSL" bash -c \
    "curl -sf -H \"\$AUTHZ\" -XPOST '$API/api/pki/issue' -d '{\"chain\":\"pqc\",\"cn\":\"verify.lab.local\"}' | jq -e '.verification.node.ok and .verification.openssl.ok and .leaf.key.family == \"post-quantum\"'"
  # Algorithm rotation on a scratch key with the root token, removed afterwards.
  vault_root vault
  vault write -f transit/keys/verify-scratch type=ecdsa-p256 >/dev/null 2>&1 || true
  local IN; IN=$(printf 'verify' | base64)
  local s1; s1=$(vault write -field=signature transit/sign/verify-scratch input="$IN" 2>/dev/null || true)
  check "scratch key: ecdsa-p256 → ml-dsa 65 under the same name" bash -c 'vault write -format=json transit/keys/verify-scratch/algorithm type=ml-dsa parameter_set=65 | jq -e ".data.latest_version_type == \"ml-dsa\""'
  check "scratch key: the v1 signature still verifies after the change" bash -c "vault write -field=valid transit/verify/verify-scratch input='$IN' signature='$s1' | grep -q true"
  vault write transit/keys/verify-scratch/config deletion_allowed=true >/dev/null 2>&1 || true
  vault delete transit/keys/verify-scratch >/dev/null 2>&1 || true
  unset VAULT_TOKEN
  check "FF1 round trip returns the fixture" bash -c \
    "e=\$(curl -sf -H \"\$AUTHZ\" -XPOST '$API/api/fpe/encode' -d '{\"items\":[{\"id\":\"card-1\"},{\"id\":\"iban-1\"},{\"id\":\"bsn-1\"}]}' | jq -c '{items:[.items[]|{id,value:.output}]}') && curl -sf -H \"\$AUTHZ\" -XPOST '$API/api/fpe/decode' -d \"\$e\" | jq -e '[.items[].matchesFixture]|all'"
}

sections=${*:-podman vault crypto identity identity_people app rooms}
for s in $sections; do
  "section_$s"
done
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || { echo "Run make doctor for the fix."; exit 1; }
echo "Browser journeys: make test-ui"
