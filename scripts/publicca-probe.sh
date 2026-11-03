#!/usr/bin/env bash
# scripts/publicca-probe.sh — optional: Vault 2.2's PKI External CA secrets
# engine (Vault as an ACME client of a public CA) against a local Pebble.
#
# Needs `make publicca-up`. Works on a scratch mount, probe-public/, which it
# removes afterwards, and writes every step to docs/publicca-probe.md. Nothing
# reaches the internet; Pebble's test CA is trusted only inside the one ACME
# account (trusted_ca), never as a listener CA.
#
# Exit 0 only when a certificate issued by Pebble arrives in Vault.
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VCRY_ROOT"

for c in vcry-pebble vcry-challtestsrv; do
  [ "$(vcry_container_state "$c")" = running ] || {
    echo "publicca-probe: $c is not running (make publicca-up)" >&2
    exit 1
  }
done

vault_node vault-1
vault_root vault
export VAULT_ADDR VAULT_TOKEN VAULT_CACERT
M=probe-public
ID=shop.vcry.test
OUT="$VCRY_ROOT/docs/publicca-probe.md"
TMP=$(mktemp -d)
ROWS=()
trap 'vault secrets disable "$M" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

row() {
  ROWS+=("| \`$1\` | $2 |")
  printf '  %-64s %s\n' "${1:0:64}" "$2"
}
api() {
  code=$(curl -s -o "$TMP/b" -w '%{http_code}' --cacert "$VAULT_CACERT" -H "X-Vault-Token: $VAULT_TOKEN" \
    -H 'content-type: application/json' -X "$1" ${3:+--data "$3"} "$VAULT_ADDR/v1/$2")
}
j() { jq -r "$1" "$TMP/b"; }
# challtestsrv's management API is only on vcry-internal: ask from a throwaway container.
mgmt() {
  podman run --rm --network vcry-internal "$(vcry_conf ALPINE_IMAGE)" \
    wget -qO- --post-data "$2" "http://challtestsrv:8055/$1" >/dev/null
}

# challtestsrv answers every DNS name with its own address, so Pebble's
# HTTP-01 check lands on it.
ip=$(podman inspect vcry-challtestsrv --format '{{(index .NetworkSettings.Networks "vcry-internal").IPAddress}}')
mgmt set-default-ipv4 "{\"ip\":\"$ip\"}"
cid=$(podman create "$(vcry_conf PEBBLE_IMAGE)")
podman cp "$cid:/test/certs/pebble.minica.pem" "$TMP/pebble-ca.pem" >/dev/null
podman rm "$cid" >/dev/null

vault secrets disable "$M" >/dev/null 2>&1 || true
vault secrets enable -path="$M" pki-external-ca >/dev/null
row "secrets enable pki-external-ca" "built into $(vault_json | jq -r .version); licence feature PKI External CA Secrets Engine"

api POST "$M/config/acme-account/pebble" "$(jq -n --rawfile ca "$TMP/pebble-ca.pem" '{directory_url:"https://pebble:14000/dir", email_contacts:["lab@vcry.test"], trusted_ca:$ca}')"
row "POST config/acme-account/pebble (directory_url, trusted_ca)" "HTTP $code, account key $(j '.data.account_keys["0"].key_type // "-"')"
api POST "$M/role/shop" '{"acme_account_name":"pebble","allowed_domains":["vcry.test"],"allowed_domain_options":["subdomains"],"allowed_challenge_types":["http-01"]}'
row "POST role/shop (vcry.test subdomains, http-01)" "HTTP $code"
api POST "$M/role/shop/new-order" "{\"identifiers\":[\"$ID\"]}"
oid=$(j .data.order_id)
row "POST role/shop/new-order identifiers=$ID" "HTTP $code, order $oid"

# The order's authorizations arrive asynchronously; ask until the token exists.
tok=""
for _ in $(seq 1 20); do
  api GET "$M/role/shop/order/$oid/challenge?identifier=$ID&challenge_type=http-01"
  tok=$(j '.data.challenge_token // empty' 2>/dev/null || true)
  [ -n "$tok" ] && break
  sleep 1
done
auth=$(j .data.challenge_auth)
row "GET role/shop/order/:id/challenge?identifier=&challenge_type=http-01" "HTTP $code, token ${tok:0:12}…"
mgmt add-http01 "{\"token\":\"$tok\",\"content\":\"$auth\"}"
row "challtestsrv add-http01 (serves the key authorization)" "done"
api POST "$M/role/shop/order/$oid/fulfilled-challenge" "{\"identifier\":\"$ID\",\"challenge_type\":\"http-01\"}"
row "POST role/shop/order/:id/fulfilled-challenge" "HTTP $code"

status=""
for _ in $(seq 1 30); do
  api GET "$M/role/shop/order/$oid/status"
  status=$(j .data.order_status)
  case "$status" in completed | error | invalid | failed) break ;; esac
  sleep 2
done
err=$(j '.data.last_error' | tr '\n\t' '  ' | sed 's/  */ /g; s/|/\\|/g')
row "GET role/shop/order/:id/status" "order_status=$status${err:+, last_error: $err}"
issued=$(podman logs --since 5m vcry-pebble 2>&1 | grep -o 'Issued certificate serial [0-9a-f]*' | tail -1 || true)
row "Pebble log" "${issued:-no certificate issued}"

api GET "$M/role/shop/order/$oid/fetch-cert?certificate_format=pem_bundle"
got=$(j '.data.certificate // empty' 2>/dev/null || true)
if [ -n "$got" ]; then
  subj=$(openssl x509 -noout -subject -issuer <<<"$got" | tr '\n' ' ')
  row "GET role/shop/order/:id/fetch-cert" "HTTP $code, $subj"
else
  row "GET role/shop/order/:id/fetch-cert" "HTTP $code, no certificate: $(j '(.errors // []) | join("; ")' | sed 's/|/\\|/g')"
fi

{
  echo "# PKI External CA against a local Pebble"
  echo
  echo "Written by \`make publicca-probe\` on $(date -u +%Y-%m-%dT%H:%MZ): vault-1"
  echo "**$(vault_json | jq -r .version)**, Pebble \`$(vcry_conf PEBBLE_IMAGE | sed 's/.*://')\`, scratch mount \`$M\` (removed)."
  echo
  echo "| Step | Result |"
  echo "| --- | --- |"
  printf '%s\n' "${ROWS[@]}"
  echo
  if [ -n "$got" ]; then echo "Outcome: **a Pebble certificate arrived in Vault.**"; else echo "Outcome: **no certificate reached Vault.** The console has no Public CA panel until it does."; fi
} >"$OUT"
echo "publicca-probe: wrote ${OUT#"$VCRY_ROOT"/}"
[ -n "$got" ]
