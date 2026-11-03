#!/usr/bin/env bash
# scripts/api-test.sh — call every cryptolab route against the live stack and
# check status and shape. Runs as olga (all four groups) with a Keycloak
# access token, then checks that Vault refuses what vera, piet and kees may
# not do. Changes demo state the way the UI does (it signs, rotates the demo
# keys, issues and revokes short-lived certificates); run `make demo-reset`
# afterwards for a clean demo.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

A="http://127.0.0.1:$(vcry_conf VCRY_PORT_API)"
pass=0; fail=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

KC="http://127.0.0.1:$(vcry_conf VCRY_PORT_KEYCLOAK)"
# A persona's Keycloak access token (lab-only client vcry-cli).
kc_token() {
  curl -s -X POST "$KC/realms/vcry/protocol/openid-connect/token" -d grant_type=password -d client_id=vcry-cli \
    -d username="$1" --data-urlencode "password=$("$VCRY_ROOT/scripts/identity-secrets.sh" --print "$1")" -d scope=openid |
    jq -r '.access_token // empty'
}
BEARER=$(kc_token olga)
[ -n "$BEARER" ] || { echo "api-test: Keycloak gave no token for olga (make identity-up && make identity-verify)" >&2; exit 1; }

# call <expected status> <method> <path> [json] → body in $TMP/b (as $BEARER)
call() {
  local want=$1 method=$2 path=$3 data=${4:-} code auth=()
  [ -n "${BEARER:-}" ] && auth=(-H "authorization: Bearer $BEARER")
  if [ -n "$data" ]; then
    code=$(curl -s -o "$TMP/b" -w '%{http_code}' -X "$method" "${auth[@]}" -H 'content-type: application/json' --data "$data" "$A$path")
  else
    code=$(curl -s -o "$TMP/b" -w '%{http_code}' -X "$method" "${auth[@]}" "$A$path")
  fi
  [ "$code" = "$want" ] || { printf '  \033[31m✗\033[0m %s %s: HTTP %s, want %s: %s\n' "$method" "$path" "$code" "$want" "$(head -c 300 "$TMP/b")"; fail=$((fail + 1)); return 1; }
}
# expect <description> <jq filter that must be true>
expect() {
  if jq -e "$2" "$TMP/b" >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  \033[31m✗\033[0m %s: %s\n' "$1" "$(head -c 300 "$TMP/b")"; fail=$((fail + 1))
  fi
}
j() { jq -r "$1" "$TMP/b"; }

echo "platform"
call 200 GET /api/health && expect "health: vault-1 unsealed Enterprise, agent token present, OpenSSL 3.5+" \
  '.ok and (.vault.sealed|not) and .vault.enterprise and .agent.tokenPresent and (.runtime.openssl|test("OpenSSL 3\\.[5-9]|OpenSSL [4-9]"))'
call 200 GET /api/capabilities && expect "capabilities: all four rooms available" '[.rooms[].available] | all'

echo "quantum pki"
call 200 GET /api/pki/chains && expect "chains: classic EC, post-quantum ML-DSA, OCSP off on PQC only" \
  '(.chains.classic.intermediate.certificate.key.family == "classic") and (.chains.pqc.root.certificate.signatureAlgorithm.name == "ML-DSA-87") and (.chains.pqc.intermediate.certificate.key.type == "ml-dsa-65") and (.chains.pqc.crl.ocspDisabled) and (.chains.classic.crl.ocspDisabled|not)'
call 200 POST /api/pki/issue '{"chain":"classic","cn":"api-test.lab.local"}' && expect "issue classic: verified by node and openssl, no private key" \
  '.verification.node.ok and .verification.openssl.ok and (.leaf.key.label == "EC P-256") and (has("private_key")|not) and (.certificate|test("PRIVATE")|not)'
classic_serial=$(j .leaf.serial); classic_bytes=$(j .leaf.bytes.der)
call 200 POST /api/pki/issue '{"chain":"pqc","cn":"api-test.lab.local"}' && expect "issue pqc: ML-DSA-44 leaf signed by ML-DSA-65, verified twice" \
  '.verification.node.ok and .verification.openssl.ok and (.leaf.key.type == "ml-dsa-44") and (.leaf.signatureAlgorithm.name == "ML-DSA-65") and (.leaf.bytes.signature == 3309)'
pqc_serial=$(j .leaf.serial); pqc_bytes=$(j .leaf.bytes.der)
[ "$pqc_bytes" -gt "$classic_bytes" ] && { printf '  \033[32m✓\033[0m the ML-DSA leaf is larger (%s vs %s bytes DER)\n' "$pqc_bytes" "$classic_bytes"; pass=$((pass + 1)); } || { echo "  ✗ sizes"; fail=$((fail + 1)); }
call 400 POST /api/pki/issue '{"chain":"classic","cn":"evil.example.com"}' && expect "issue refuses names outside lab.local" '.ok == false'
call 200 GET "/api/pki/ocsp?chain=classic&serial=$classic_serial" && expect "OCSP classic: good, signature verified" '.status == "good" and .signatureVerified'
call 200 GET "/api/pki/ocsp?chain=pqc&serial=$pqc_serial" && expect "OCSP pqc: Vault's refusal returned as is" '.status == "responder-error" and (.responderError | length > 0)'
call 200 GET "/api/pki/crl?chain=pqc&serial=$pqc_serial" && expect "CRL pqc: ML-DSA-65-signed, the fresh leaf is not on it" '.available and .signatureAlgorithm == "ML-DSA-65" and (.listed | not)'
call 200 GET /api/pki/move && expect "move evidence: source is ML-DSA-65 on pki-pqc-int" '.source.keyType == "ml-dsa" and .source.parameterSet == "ml-dsa-65"'

echo "crypto agility"
call 200 GET /api/agility && expect "agility: both demo keys readable" '.keys["orders-signing"].usage == "signing" and .keys["ledger-data"].usage == "encryption"'
call 200 POST /api/agility/sign '{"message":"api-test before"}' && expect "sign" '.entry.signature | startswith("vault:v")'
latest=$(curl -s "$A/api/agility" | jq -r '.keys["orders-signing"].vault.latest_version_type')
next=$([ "$latest" = "ml-dsa" ] && echo hybrid-ml-dsa-65-ecdsa-p256 || echo ml-dsa-65)
call 200 POST /api/agility/rotate "{\"key\":\"orders-signing\",\"target\":\"$next\"}" && expect "rotate orders-signing ($latest → $next)" '.vault.latest_version_type | test("ml-dsa|hybrid")'
call 200 POST /api/agility/sign '{"message":"api-test after"}' && expect "sign with the new version" '.entry.family == "post-quantum"'
call 200 POST /api/agility/verify && expect "every earlier signature still verifies" '[.results[].valid] | all'
call 400 POST /api/agility/rotate '{"key":"orders-signing","target":"aes256-gcm96"}' && expect "cross-usage rotation refused with Vault's own text" '(.vault[0] | test("incompatible algorithm"))'
call 400 POST /api/agility/rotate '{"key":"autounseal","target":"ml-dsa-65"}' && expect "only the two demo keys" '.ok == false'
call 200 POST /api/agility/ledger/encrypt '{"label":"api-test ledger line"}' && expect "ledger encrypt" '.entry.version >= 1'
call 200 POST /api/agility/rotate '{"key":"ledger-data","target":"aes256-gcm96"}' && expect "rotate ledger-data" '.vault.latest_version_type == "aes256-gcm96"'
call 200 POST /api/agility/ledger/rewrap && expect "batch rewrap to the latest version" '.rewrapped >= 1 and (.errors | length == 0)'
call 200 POST /api/agility/ledger/decrypt && expect "decrypt equals what was encrypted" '[.entries[].equal] | all'

echo "format-preserving"
call 200 GET /api/fpe && expect "transformations are FF1" '[.transformations[].fpe_algorithm] | all(. == "ff1")'
items=$(jq -c '{items: [.fixtures[] | {id}]}' "$TMP/b")
call 200 POST /api/fpe/encode "$items" && expect "encode keeps every shape" '[.items[].check.shape] | all'
enc=$(jq -c '{items: [.items[] | {id, value: .output}]}' "$TMP/b")
call 200 POST /api/fpe/decode "$enc" && expect "decode returns every fixture" '[.items[].matchesFixture] | all'
call 200 POST /api/fpe/rewrap "$enc" && expect "rewrap moves the cards ccn-legacy → ccn-2026" '.to == "ccn-2026" and ([.items[].output] | all(. != null))'
rw=$(jq -c '{items: [.items[] | {id, value: .output, transformation: "ccn-2026"}]}' "$TMP/b")
call 200 POST /api/fpe/decode "$rw" && expect "rewrapped cards decode under ccn-2026" '[.items[].matchesFixture] | all'
call 400 POST /api/fpe/encode '{"items":[{"id":"not-a-fixture"}]}' && expect "only fixture rows reach Vault" '.ok == false'

echo "lifecycle"
# pki-pqc-next has no issuer (and so no CRL) until make pki-move.
call 200 GET /api/certs && expect "inventory covers three mounts, both chains' CRLs readable" '(.totals | length == 3) and ([.crl[] | select(.mount != "pki-pqc-next") | .available] | all)'
call 200 POST /api/certs/revoke "{\"mount\":\"pki-pqc-int\",\"serial\":\"$pqc_serial\"}" && expect "revoke: listed on the ML-DSA-signed CRL" '.state == "revoked" and .crl.listed and .crl.signatureAlgorithm == "ML-DSA-65"'
call 200 GET "/api/pki/crl?chain=pqc&serial=$pqc_serial" && expect "CRL pqc: the revoked leaf is listed" '.listed and (.revokedAt | length > 0)'
call 200 POST /api/certs/revoke "{\"mount\":\"pki-classic-int\",\"serial\":\"$classic_serial\"}" && expect "revoke classic" '.state == "revoked"'
call 400 POST /api/certs/revoke "{\"mount\":\"pki-pqc-root\",\"serial\":\"$pqc_serial\"}" && expect "revoke refuses the root mount" '.ok == false'
call 404 GET /api/nope && expect "unknown route: 404" '.ok == false'

echo "who may do what (Vault refuses, the API passes it on)"
call 200 GET /api/me && expect "olga: four policies, may issue, rotate and decode" \
  '(.policies | length == 4) and .actions["pki.issue.pqc"].allowed and .actions["agility.rotate"].allowed and .actions["fpe.decode"].allowed'
olga=$BEARER
BEARER=""
call 401 GET /api/pki/chains && expect "signed out: rooms answer 401 with the sign-in path" '.signIn == "/auth/login"'
call 200 GET /api/me && expect "signed out: /api/me says so" '.signedIn == false'
BEARER=$(kc_token vera)
call 200 GET /api/me && expect "vera: viewer only, Vault says she may not issue" '(.policies == ["vcry-viewer"]) and (.actions["pki.issue.pqc"].allowed | not)'
call 200 GET /api/certs && expect "vera may read the inventory" '.totals | length == 3'
call 403 POST /api/pki/issue '{"chain":"pqc","cn":"vera.lab.local"}' && expect "vera may not issue: Vault says permission denied" '.vault[0] | test("permission denied")'
call 403 POST /api/agility/rotate '{"key":"orders-signing","target":"ml-dsa-65"}' && expect "vera may not change an algorithm" '.status == 403'
BEARER=$(kc_token piet)
call 200 POST /api/pki/issue '{"chain":"pqc","cn":"piet.lab.local"}' && expect "piet (PKI operator) may issue ML-DSA" '.leaf.key.type == "ml-dsa-44"'
call 403 POST /api/agility/rotate '{"key":"orders-signing","target":"ml-dsa-65"}' && expect "piet may not change an algorithm" '.status == 403'
BEARER=$(kc_token kees)
call 200 POST /api/agility/sign '{"message":"kees signs"}' && expect "kees (key custodian) may sign" '.entry.version >= 1'
call 403 POST /api/fpe/decode '{"items":[{"id":"card-1","value":"1234-5678-9012-3456"}]}' && expect "kees may not decode FF1 values" '.status == 403'
BEARER=$(kc_token dana)
call 200 POST /api/fpe/encode '{"items":[{"id":"card-1"}]}' && expect "dana (data steward) may encode" '.items[0].output != null'
call 403 POST /api/pki/issue '{"chain":"classic","cn":"dana.lab.local"}' && expect "dana may not issue" '.status == 403'
BEARER=$olga

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
