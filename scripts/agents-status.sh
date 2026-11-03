#!/usr/bin/env bash
# scripts/agents-status.sh — every machine identity end to end: rotator
# health, credential validity, secret-id expiry, agent health and token TTL.
# Read-only. Exit 1 when anything in a chain is broken.
set -uo pipefail
failed=0
state() { podman inspect "$1" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || echo "not created"; }

# plane | rotator container | role | agent container
IDENTITIES="seal vcry-seal-rotator seal-autounseal vcry-seal-agent
app  vcry-rotator       cryptolab-api    vcry-vault-agent
app  vcry-rotator       web-tls     vcry-tls-agent"

printf '%-5s %-20s %-10s %-10s %-20s %-21s %-10s %s\n' PLANE IDENTITY ROTATOR CREDENTIAL SECRET-ID-EXPIRES LAST-ROTATION AGENT TOKEN-TTL
while read -r plane rot role agent; do
  rs=$(state "$rot")
  login=$(podman exec "$rot" sh -c 't=$(vault write -field=token auth/approle/login role_id="$(cat /run/rotator/role-id)" secret_id="$(cat /run/rotator/secret-id)" 2>/dev/null) && VAULT_TOKEN=$t vault token revoke -self >/dev/null 2>&1 && echo ok || echo REJECTED' 2>/dev/null || echo "-")
  meta=$(podman exec "$rot" cat "/run/approle/$role/metadata.json" 2>/dev/null || echo '{}')
  as=$(state "$agent")
  ttl=$(podman exec "$agent" sh -c 'VAULT_TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null) vault token lookup -format=json 2>/dev/null' 2>/dev/null | jq -r '.data.ttl // empty' 2>/dev/null)
  if [ -n "$ttl" ]; then ttl="$((ttl / 60))m"; else
    ttl=REJECTED
    failed=1
  fi
  { [ "$rs" = healthy ] && [ "$login" = ok ]; } || failed=1
  printf '%-5s %-20s %-10s %-10s %-20s %-21s %-10s %s\n' "$plane" "$role" "$rs" "$login" \
    "$(jq -r '.expiration_time // "-"' <<<"$meta" | cut -c1-19)" "$(jq -r '.last_rotation_utc // "-"' <<<"$meta")" "$as" "$ttl"
done <<<"$IDENTITIES"
echo
"$(dirname -- "$0")/seal-token-status.sh" || failed=1
exit "$failed"
