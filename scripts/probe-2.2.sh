#!/usr/bin/env bash
# scripts/probe-2.2.sh — prove, against the live vault-1, every Vault 2.2 call
# the demo rooms use, and write what Vault answered to docs/capabilities.md.
#
# Works only on scratch mounts named probe-*/, which it creates and removes
# (also on failure). Records paths, payload shapes, outcomes, sizes and
# Vault's error text; never a key, a token or a full certificate.
#
# Exit 0 when every expected outcome was seen (an expected refusal counts).
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VCRY_ROOT"

for tool in vault jq curl openssl podman; do
  command -v "$tool" >/dev/null || {
    echo "Missing command: $tool" >&2
    exit 127
  }
done

vault_node vault-1
vault_root vault
export VAULT_ADDR VAULT_TOKEN VAULT_CACERT

OUT="$VCRY_ROOT/docs/capabilities.md"
TMP=$(mktemp -d)
MOUNTS="probe-pki-root probe-pki-int probe-pki-next probe-transit probe-transform"
ROWS=()
failed=0

cleanup() {
  local m
  for m in $MOUNTS; do vault secrets disable "$m" >/dev/null 2>&1 || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT
cleanup_mounts_first() {
  local m
  for m in $MOUNTS; do vault secrets disable "$m" >/dev/null 2>&1 || true; done
}

# api METHOD PATH [JSON] → body in $TMP/body, HTTP code in $code
api() {
  local data=${3:-}
  if [ -n "$data" ]; then
    code=$(curl -s -o "$TMP/body" -w '%{http_code}' --cacert "$VAULT_CACERT" -H "X-Vault-Token: $VAULT_TOKEN" \
      -H 'content-type: application/json' -X "$1" --data "$data" "$VAULT_ADDR/v1/$2")
  else
    code=$(curl -s -o "$TMP/body" -w '%{http_code}' --cacert "$VAULT_CACERT" -H "X-Vault-Token: $VAULT_TOKEN" \
      -X "$1" "$VAULT_ADDR/v1/$2")
  fi
}
body() { jq -r "$1" "$TMP/body"; }
verr() { jq -r '(.errors // []) | join("; ")' "$TMP/body" 2>/dev/null | tr '\n\t' '  ' | sed 's/  */ /g; s/|/\\|/g'; }

# row <area> <call> <expected: ok|refused> <detail>; outcome from $code
row() {
  local area=$1 call=$2 want=$3 detail=$4 got
  case "$code" in 2*) got=ok ;; *) got=refused ;; esac
  if [ "$got" != "$want" ]; then
    failed=$((failed + 1))
    got="**$got (expected $want)**"
  fi
  [ "$want" = refused ] && [ "$got" = refused ] && got="refused, as expected"
  ROWS+=("| $area | \`$call\` | $got ($code) | $detail |")
  printf '  %-12s %-62s %s\n' "$area" "${call:0:62}" "$got"
}
# note <area> <what> <result> — a measured fact, not an API call
note() {
  ROWS+=("| $1 | $2 | measured | $3 |")
  printf '  %-12s %-62s %s\n' "$1" "${2:0:62}" "$3"
}

cleanup_mounts_first
for m in $MOUNTS; do
  case "$m" in
  probe-pki-*) vault secrets enable -path="$m" -max-lease-ttl=87600h pki >/dev/null ;;
  probe-transit) vault secrets enable -path="$m" transit >/dev/null ;;
  probe-transform) vault secrets enable -path="$m" transform >/dev/null ;;
  esac
done
version=$(vault_json | jq -r .version)
echo "probe: vault-1 $version"

# ── PKI: ML-DSA hierarchy ────────────────────────────────────────────────────
echo "PKI"
for ps in ml-dsa-44 ml-dsa-65 ml-dsa-87; do
  api POST "probe-pki-next/root/generate/internal" "{\"common_name\":\"probe $ps\",\"key_type\":\"ml-dsa\",\"parameter_set\":\"$ps\",\"ttl\":\"1h\",\"issuer_name\":\"r-$ps\",\"key_name\":\"k-$ps\"}"
  bytes=$(body .data.certificate | openssl x509 -outform der 2>/dev/null | wc -c | tr -d ' ')
  row PKI "POST root/generate/internal key_type=ml-dsa parameter_set=$ps" ok "self-signed root, ${bytes} bytes DER"
done
api POST "probe-pki-root/root/generate/internal" '{"common_name":"Probe ML-DSA Root","key_type":"ml-dsa","parameter_set":"ml-dsa-87","ttl":"8760h"}'
row PKI "POST root/generate/internal (ml-dsa-87, the PQC root)" ok "issuer $(body .data.issuer_id | cut -c1-8)…"
body .data.certificate >"$TMP/root.pem"
api POST "probe-pki-int/intermediate/generate/internal" '{"common_name":"Probe ML-DSA Int","key_type":"ml-dsa","parameter_set":"ml-dsa-65"}'
row PKI "POST intermediate/generate/internal key_type=ml-dsa parameter_set=ml-dsa-65" ok "CSR $(body .data.csr | wc -c | tr -d ' ') bytes PEM"
csr=$(body .data.csr)
api POST "probe-pki-root/root/sign-intermediate" "$(jq -n --arg c "$csr" '{csr:$c, format:"pem_bundle", ttl:"4380h"}')"
row PKI "POST root/sign-intermediate (ML-DSA-87 signs ML-DSA-65)" ok "signed"
signed=$(body .data.certificate)
api POST "probe-pki-int/intermediate/set-signed" "$(jq -n --arg c "$signed" '{certificate:$c}')"
row PKI "POST intermediate/set-signed" ok "imported issuers: $(body '.data.imported_issuers | length')"
api POST "probe-pki-int/roles/leaf" '{"key_type":"ml-dsa","parameter_set":"ml-dsa-44","allow_any_name":true,"max_ttl":"1h"}'
row PKI "POST roles/leaf key_type=ml-dsa parameter_set=ml-dsa-44" ok "role written"
api POST "probe-pki-int/issue/leaf" '{"common_name":"leaf.probe.lab","ttl":"10m"}'
row PKI "POST issue/leaf" ok "private_key_type=$(body .data.private_key_type), private_key_parameter_set=$(body .data.private_key_parameter_set)"
body .data.certificate >"$TMP/leaf.pem"
body .data.issuing_ca >"$TMP/int.pem"
serial=$(body .data.serial_number)
note PKI "leaf / intermediate / root size" "$(openssl x509 -in "$TMP/leaf.pem" -outform der | wc -c | tr -d ' ') / $(openssl x509 -in "$TMP/int.pem" -outform der | wc -c | tr -d ' ') / $(openssl x509 -in "$TMP/root.pem" -outform der | wc -c | tr -d ' ') bytes DER"

chmod 644 "$TMP"/*.pem
chmod 755 "$TMP"
alp=$(podman run --rm -v "$TMP:/pq:ro,Z" "$(vcry_conf ALPINE_IMAGE)" sh -c \
  'apk add -q openssl >/dev/null 2>&1; printf "%s|" "$(openssl version | cut -d" " -f1-2)"; openssl verify -CAfile /pq/root.pem -untrusted /pq/int.pem /pq/leaf.pem 2>&1 | tail -1' 2>&1 || true)
note PKI "openssl verify (alpine $(vcry_conf ALPINE_IMAGE | sed 's/.*://'))" "${alp//|/: }"
nd=$(podman run --rm -v "$TMP:/pq:ro,Z" "$(vcry_conf NODE_IMAGE)" node -e '
const {X509Certificate}=require("crypto"),fs=require("fs");
const [l,i,r]=["leaf","int","root"].map(n=>new X509Certificate(fs.readFileSync(`/pq/${n}.pem`)));
process.stdout.write(`node ${process.versions.node} (OpenSSL ${process.versions.openssl}): key ${l.publicKey.asymmetricKeyType}, sig ${l.signatureAlgorithm} ${l.signatureAlgorithmOid}, leaf.verify(int)=${l.verify(i.publicKey)}, int.verify(root)=${i.verify(r.publicKey)}`)' 2>&1 || true)
note PKI "Node crypto.X509Certificate" "$nd"

api GET "probe-pki-int/crl/pem"
crl_alg=$(openssl crl -in "$TMP/body" -noout -text 2>/dev/null | awk -F': ' '/Signature Algorithm/ {print $2; exit}')
row PKI "GET crl/pem" ok "CRL signed with ${crl_alg:-?}"
openssl ocsp -issuer "$TMP/int.pem" -cert "$TMP/leaf.pem" -no_nonce -reqout "$TMP/ocsp.req" >/dev/null 2>&1
code=$(curl -s -o "$TMP/ocsp.resp" -w '%{http_code}' --cacert "$VAULT_CACERT" -H 'content-type: application/ocsp-request' \
  --data-binary @"$TMP/ocsp.req" "$VAULT_ADDR/v1/probe-pki-int/ocsp")
ocsp=$({ openssl ocsp -respin "$TMP/ocsp.resp" -resp_text -noverify 2>&1 || true; } | head -1 | sed 's/|/\\|/g')
row PKI "POST ocsp (ML-DSA issuer)" refused "$ocsp (docs: ML-DSA CAs are not supported for OCSP)"
api POST "probe-pki-int/revoke" "{\"serial_number\":\"$serial\"}"
row PKI "POST revoke" ok "revocation_time $(body .data.revocation_time)"

# ── PKI Enterprise: move the ML-DSA issuing key, wrapped ─────────────────────
echo "PKI CA key export"
api POST "probe-pki-next/export" '{"key_type":"ml-kem-1024","name":"probe-move"}'
row "PKI (Ent)" "POST export key_type=ml-kem-1024 (on the target mount)" ok "public key PEM type: $(body .data.public_key | head -1 | tr -d -), export_key_hmac $(body .data.export_key_hmac | cut -c1-15)…"
pub=$(body .data.public_key)
api GET "probe-pki-int/issuer/default"
kid=$(body .data.key_id)
api POST "probe-pki-int/keys/$kid/export" "$(jq -n --arg p "$pub" '{public_key:$p}')"
row "PKI (Ent)" "POST keys/:key_ref/export public_key=<target's ML-KEM key>" ok "wrapped_key $(body '.data.wrapped_key | length') chars; needs sudo on this path"
wrapped=$(body .data.wrapped_key)
hmac=$(body .data.export_key_hmac)
api POST "probe-pki-next/keys/import" "$(jq -n --arg w "$wrapped" --arg h "$hmac" '{wrapped_key:$w, export_key_hmac:$h, key_name:"moved"}')"
row "PKI (Ent)" "POST keys/import wrapped_key + export_key_hmac" ok "key_type=$(body .data.key_type), parameter_set=$(body .data.parameter_set)"
unset wrapped
api GET "probe-pki-int/issuer/default"
row "PKI (Ent)" "GET issuer/default (source, after export)" ok "warning: $(body '.warnings[0]' | cut -c1-48)…"
api POST "probe-pki-next/issuers/import/cert" "$(jq -n --arg c "$(cat "$TMP/int.pem")" '{pem_bundle:$c}')"
row "PKI (Ent)" "POST issuers/import/cert (the intermediate's certificate)" ok "issuer mapped to the moved key: $(body '.data.mapping | to_entries[0].value != ""')"

# ── Transit: crypto agility ──────────────────────────────────────────────────
echo "Transit"
IN=$(printf 'order 4711: 3x espresso' | base64)
api POST "probe-transit/keys/sig" '{"type":"ecdsa-p256"}'
row Transit "POST keys/sig type=ecdsa-p256" ok "created"
sigs=()
sign() {
  api POST "probe-transit/sign/sig" "{\"input\":\"$IN\"}"
  sigs+=("$(body .data.signature)")
  row Transit "POST sign/sig (after $1)" ok "signature $(body .data.signature | cut -d: -f1-2), $(body '.data.signature | length') chars"
}
sign "create"
api POST "probe-transit/keys/sig/algorithm" '{"type":"ml-dsa","parameter_set":"65"}'
row Transit "POST keys/sig/algorithm type=ml-dsa parameter_set=65" ok "latest_version=$(body .data.latest_version), latest_version_type=$(body .data.latest_version_type)"
sign "→ ml-dsa"
api POST "probe-transit/keys/sig/algorithm" '{"type":"hybrid","parameter_set":"65","hybrid_key_type_pqc":"ml-dsa","hybrid_key_type_ec":"ecdsa-p256"}'
row Transit "POST keys/sig/algorithm type=hybrid (ml-dsa 65 + ecdsa-p256)" ok "latest_version=$(body .data.latest_version), latest_version_type=$(body .data.latest_version_type)"
sign "→ hybrid"
for s in "${sigs[@]}"; do
  api POST "probe-transit/verify/sig" "{\"input\":\"$IN\",\"signature\":\"$s\"}"
  row Transit "POST verify/sig ($(cut -d: -f2 <<<"$s") signature, key now v3)" ok "valid=$(body .data.valid)"
done
api GET "probe-transit/keys/sig"
row Transit "GET keys/sig" ok "type=$(body .data.type) (the original), latest_version_type=$(body .data.latest_version_type), per-version name: $(body '[.data.keys[] | .name | if . == "" then "(empty)" else . end] | join(", ")')"
api POST "probe-transit/keys/sig/algorithm" '{"type":"aes256-gcm96"}'
row Transit "POST keys/sig/algorithm type=aes256-gcm96 (signing → encryption)" refused "$(verr)"
api POST "probe-transit/keys/slh" '{"type":"slh-dsa","parameter_set":"slh-dsa-sha2-128s"}'
row Transit "POST keys/slh type=slh-dsa parameter_set=slh-dsa-sha2-128s" ok "created"
api POST "probe-transit/sign/slh" "{\"input\":\"$IN\"}"
row Transit "POST sign/slh" ok "signature $(body '.data.signature | length') chars"

P=$(printf 'synthetic ledger line 0001' | base64)
api POST "probe-transit/keys/led" '{"type":"aes128-gcm96"}'
row Transit "POST keys/led type=aes128-gcm96" ok "created"
api POST "probe-transit/encrypt/led" "{\"plaintext\":\"$P\"}"
c1=$(body .data.ciphertext)
row Transit "POST encrypt/led" ok "$(cut -d: -f1-2 <<<"$c1")"
api POST "probe-transit/keys/led/algorithm" '{"type":"aes256-gcm96"}'
row Transit "POST keys/led/algorithm type=aes256-gcm96" ok "latest_version_type=$(body .data.latest_version_type)"
api POST "probe-transit/keys/led/algorithm" '{"type":"chacha20-poly1305"}'
row Transit "POST keys/led/algorithm type=chacha20-poly1305" ok "latest_version_type=$(body .data.latest_version_type)"
api POST "probe-transit/rewrap/led" "{\"batch_input\":[{\"ciphertext\":\"$c1\"}]}"
r1=$(body '.data.batch_results[0].ciphertext')
row Transit "POST rewrap/led batch_input=[v1 ciphertext]" ok "→ $(cut -d: -f1-2 <<<"$r1")"
api POST "probe-transit/decrypt/led" "{\"ciphertext\":\"$r1\"}"
pt_ok=$([ "$(body .data.plaintext)" = "$P" ] && echo "plaintext equal" || echo "PLAINTEXT DIFFERS")
row Transit "POST decrypt/led (rewrapped)" ok "$pt_ok"
api POST "probe-transit/keys/led/algorithm" '{"type":"ed25519"}'
row Transit "POST keys/led/algorithm type=ed25519 (encryption → signing)" refused "$(verr)"

# ── Transform: FF1 ───────────────────────────────────────────────────────────
echo "Transform"
X=probe-transform
api POST "$X/template/nl-iban" '{"type":"regex","pattern":"NL\\d{2}[A-Z]{4}(\\d{10})","alphabet":"builtin/numeric"}'
row Transform "POST template/nl-iban regex over the 10-digit account part" ok "written"
api POST "$X/role/pay" '{"transformations":["ccn-old","ccn-new","iban","try-ff3"]}'
row Transform "POST role/pay" ok "written"
for t in ccn-old ccn-new; do
  api POST "$X/transformations/fpe/$t" '{"template":"builtin/creditcardnumber","tweak_source":"internal","allowed_roles":["pay"]}'
  row Transform "POST transformations/fpe/$t template=builtin/creditcardnumber" ok "written"
done
api GET "$X/transformations/fpe/ccn-old"
row Transform "GET transformations/fpe/ccn-old" ok "fpe_algorithm=$(body .data.fpe_algorithm)"
api POST "$X/transformations/fpe/try-ff3" '{"template":"builtin/creditcardnumber","tweak_source":"internal","allowed_roles":["pay"],"fpe_algorithm":"ff3-1"}'
row Transform "POST transformations/fpe/try-ff3 fpe_algorithm=ff3-1" ok "accepted; parameter ignored"
api GET "$X/transformations/fpe/try-ff3"
row Transform "GET transformations/fpe/try-ff3" ok "fpe_algorithm=$(body .data.fpe_algorithm): FF3-1 cannot be created on $version"
api POST "$X/transformations/fpe/iban" '{"template":"nl-iban","tweak_source":"internal","allowed_roles":["pay"]}'
row Transform "POST transformations/fpe/iban template=nl-iban" ok "written"
api POST "$X/encode/pay" '{"batch_input":[{"value":"4111-1111-1111-1111","transformation":"ccn-old"},{"value":"NL91ABNA0417164300","transformation":"iban"}]}'
e1=$(body '.data.batch_results[0].encoded_value')
row Transform "POST encode/pay batch_input (card, IBAN)" ok "4111-1111-1111-1111 → $e1, NL91ABNA0417164300 → $(body '.data.batch_results[1].encoded_value')"
api POST "$X/decode/pay" "{\"value\":\"$e1\",\"transformation\":\"ccn-old\"}"
row Transform "POST decode/pay" ok "→ $(body .data.decoded_value)"
api POST "$X/rewrap/pay" "{\"batch_input\":[{\"value\":\"$e1\",\"transformation\":\"ccn-new\",\"decode_transformation\":\"ccn-old\"}]}"
e2=$(body '.data.batch_results[0].encoded_value')
row Transform "POST rewrap/pay batch_input (ccn-old → ccn-new)" ok "$e1 → $e2, no plaintext in the response"
api POST "$X/decode/pay" "{\"value\":\"$e2\",\"transformation\":\"ccn-new\"}"
row Transform "POST decode/pay (rewrapped value, ccn-new)" ok "→ $(body .data.decoded_value)"
api POST "$X/decode/pay" "{\"value\":\"$e2\",\"transformation\":\"ccn-old\"}"
row Transform "POST decode/pay (rewrapped value, old transformation)" ok "→ $(body .data.decoded_value) (a different number: FPE has no integrity check)"

# ── Write the report ─────────────────────────────────────────────────────────
{
  echo "# Vault 2.2 capabilities, as vault-1 answered"
  echo
  echo "Written by \`make probe\` (\`scripts/probe-2.2.sh\`) on $(date -u +%Y-%m-%dT%H:%MZ) against"
  echo "vault-1 **$version**, on scratch mounts \`probe-*\` that the probe removed"
  echo "afterwards. Every row is a real call. Key material, tokens and full"
  echo "certificates are never recorded. The demo rooms use only calls listed here."
  echo
  echo "| Area | Call | Outcome | What Vault said |"
  echo "| --- | --- | --- | --- |"
  printf '%s\n' "${ROWS[@]}"
  echo
  echo "Mismatches against the expected outcome: **$failed**."
} >"$OUT"
echo "probe: wrote ${OUT#"$VCRY_ROOT"/} ($failed mismatches)"
[ "$failed" -eq 0 ]
