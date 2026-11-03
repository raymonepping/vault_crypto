#!/usr/bin/env bash
# scripts/web-cert.sh — the certificate the web UI presents right now, read
# off the wire and verified against Vault's pki-classic-root. Read-only.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

port=$(vcry_conf VCRY_PORT_WEB)
vault_node vault-1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -sf --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/pki-classic-root/ca/pem" >"$tmp/root.pem" ||
  { echo "web-cert: cannot read pki-classic-root from vault-1 (make vault-up)" >&2; exit 1; }
out=$(openssl s_client -connect "127.0.0.1:$port" -servername localhost -verify_hostname localhost \
  -CAfile "$tmp/root.pem" -showcerts </dev/null 2>/dev/null) ||
  { echo "web-cert: nothing answers TLS on 127.0.0.1:$port (make app-up)" >&2; exit 1; }
openssl x509 -noout -subject -issuer -serial -startdate -enddate <<<"$out" | sed 's/^/  /'
end=$(openssl x509 -noout -enddate <<<"$out" | cut -d= -f2)
left=$(( $(date -j -f '%b %e %T %Y %Z' "$end" +%s 2>/dev/null || date -d "$end" +%s) - $(date +%s) ))
echo "  expires in $((left / 60))m $((left % 60))s — tls-agent renews it before then"
grep -q 'Verify return code: 0' <<<"$out" && echo "  chain: verifies against pki-classic-root for 'localhost'" ||
  { echo "  chain: DOES NOT VERIFY: $(grep 'Verify return code' <<<"$out")"; exit 1; }
