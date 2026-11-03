#!/usr/bin/env bash
# scripts/doctor.sh — what is wrong, and which make target fixes it. Read-only.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VCRY_ROOT"

problems=0
good() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fix() {
  printf '  \033[31m✗\033[0m %s\n      fix: %s\n' "$1" "$2"
  problems=$((problems + 1))
}

echo "host"
if [ "$(uname -s)" = Darwin ]; then
  vm=$(podman machine ssh date +%s 2>/dev/null | tr -d '\r' | tail -1 || true)
  if [ -n "$vm" ]; then
    skew=$(($(date +%s) - vm))
    skew=${skew#-}
    if [ "$skew" -gt 30 ]; then fix "VM clock is ${skew}s off the host" "make clock-sync"; else good "VM clock skew ${skew}s"; fi
  else
    fix "cannot reach the Podman machine" "podman machine start"
  fi
fi
[ -s .env ] && good ".env present" || fix ".env missing" "make env-init"
[ -s .secrets/vault/vault.hclic ] && good "ENT licence present" || fix "ENT licence missing" "make license"
openssl verify -CAfile vault-tls/ca-chain.pem vault-tls/vault.crt >/dev/null 2>&1 && good "listener certificate verifies" || fix "listener certificate missing or does not verify" "make gen-certs"

echo "containers"
for c in vcry-vault-s vcry-seal-rotator vcry-seal-agent vcry-vault-1 vcry-openldap vcry-keycloak vcry-rotator vcry-vault-agent vcry-tls-agent vcry-api vcry-web; do
  s=$(vcry_container_state "$c")
  case "$c:$s" in
  *:running) good "$c running" ;;
  vcry-vault-s:* | vcry-vault-1:* | vcry-seal-*) fix "$c is $s" "make vault-up" ;;
  vcry-openldap:* | vcry-keycloak:*) fix "$c is $s" "make identity-up" ;;
  *) fix "$c is $s" "make app-up" ;;
  esac
done

# Detect stale bind mounts.
for c in $(podman ps -a --filter name=^vcry- --format '{{.Names}}'); do
  missing=$(podman inspect "$c" --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' 2>/dev/null |
    while read -r src; do [ -z "$src" ] || [ -e "$src" ] || echo "$src"; done)
  [ -z "$missing" ] || fix "$c mounts a path that no longer exists (${missing%%$'\n'*}); it cannot restart" "make up (recreates containers from current compose files)"
done

echo "vault"
for node in vault-s vault-1; do
  cluster=$(vault_cluster_of "$node")
  file="$VCRY_STATE/$cluster-init.json"
  [ "$(vcry_container_state "$(vault_container "$node")")" = running ] || continue
  vault_node "$node"
  if ! s=$(vault_json 2>/dev/null); then
    fix "$node does not answer" "make vault-up"
    continue
  fi
  init=$(jq -r .initialized <<<"$s")
  if [ "$init" = true ] && [ ! -s "$file" ]; then
    fix "$node is initialized but .secrets/vault/$cluster-init.json is missing" "restore it from backups/*/secrets.tar"
  elif [ "$init" = false ] && [ -s "$file" ]; then
    fix "$node has saved credentials but no storage (volume lost)" "make clean-slate && make bootstrap"
  elif [ "$init" = false ]; then
    fix "$node is not initialized" "make vault-bootstrap"
  elif jq -e .sealed <<<"$s" >/dev/null; then
    if [ "$node" = vault-s ]; then fix "vault-s is sealed" "make unseal"; else fix "vault-1 is sealed" "make vault-up"; fi
  else
    good "$node initialized and unsealed"
  fi
done

echo "terraform"
for r in vault-seal vault-platform vault-crypto vault-identity; do
  [ -s ".secrets/terraform/$r.tfstate" ] && good "$r state present" || fix "$r has no state" "make tf-all"
done

echo "vault 2.2 rooms"
if [ "$(vcry_container_state vcry-vault-1)" = running ]; then
  if "$VCRY_ROOT/scripts/license-features.sh" >/dev/null 2>&1; then
    good "the licence has every feature the rooms need"
  else
    fix "the licence lacks a feature a room needs (that room shows 'not licensed')" "make license-features; install a licence with it: make license FORCE=1"
  fi
  vault_node vault-1
  vault_root vault
  for k in orders-signing ledger-data; do
    vault read "transit/keys/$k" >/dev/null 2>&1 && good "demo key $k present" || fix "demo key $k missing" "make demo-seed"
  done
  unset VAULT_TOKEN
fi
[ -s docs/capabilities.md ] && good "docs/capabilities.md present ($(grep -o 'Mismatches against the expected outcome: \*\*[0-9]*' docs/capabilities.md | grep -o '[0-9]*$' || echo '?') mismatches)" ||
  fix "no capability report for this Vault version" "make probe"

echo "app identity"
if [ "$(vcry_container_state vcry-vault-agent)" = running ]; then
  if podman exec vcry-vault-agent sh -c 'VAULT_TOKEN=$(cat /vault/secrets/token) vault token lookup >/dev/null' 2>/dev/null; then
    good "agent token valid"
  else
    fix "agent token missing or rejected" "make agents-recover"
  fi
fi
if [ "$(vcry_container_state vcry-web)" = running ]; then
  if "$VCRY_ROOT/scripts/web-cert.sh" >/dev/null 2>&1; then
    good "web certificate verifies against pki-classic-root"
  else
    fix "the web UI's certificate is missing, expired or does not verify" "make agents-status, then make agents-recover"
  fi
fi
[ -s "$VCRY_STATE/rotator/secret-id" ] && good "app rotator credential present" || fix "the app rotator has no credential" "make rotator-bootstrap"
[ -s "$VCRY_STATE/seal-rotator/secret-id" ] && good "seal rotator credential present" || fix "the seal rotator has no credential" "make tf-seal && make rotator-bootstrap && make seal-up"
if [ "$(vcry_container_state vcry-seal-rotator)" = running ] &&
  ! podman exec vcry-seal-rotator sh -c 't=$(vault write -field=token auth/approle/login role_id="$(cat /run/rotator/role-id)" secret_id="$(cat /run/rotator/secret-id)" 2>/dev/null) && VAULT_TOKEN=$t vault token revoke -self >/dev/null 2>&1' 2>/dev/null; then
  fix "the seal rotator's own credential is rejected" "make agents-recover"
fi
if [ "$(vcry_container_state vcry-rotator)" = running ]; then
  if podman exec vcry-rotator sh -c 't=$(vault write -field=token auth/approle/login role_id="$(cat /run/rotator/role-id)" secret_id="$(cat /run/rotator/secret-id)" 2>/dev/null) && VAULT_TOKEN=$t vault token revoke -self >/dev/null 2>&1' 2>/dev/null; then
    good "app rotator can log in"
  else
    fix "the rotator's own credential is rejected (it cannot rotate anything)" "make agents-recover"
  fi
fi
if [ "$(vcry_container_state vcry-vault-1)" = running ]; then
  st=$("$VCRY_ROOT/scripts/seal-token-status.sh" 2>/dev/null) && sc=0 || sc=$?
  if [ "$sc" -ne 0 ]; then
    fix "vault-1's seal token REJECTED by vault-s: it runs, but would not unseal after a restart" "make vault-recreate"
  elif grep -q "bootstrap fallback" <<<"$st"; then
    fix "vault-1 runs on the bootstrap fallback seal token, not the seal agent's" "make seal-up && make vault-recreate"
  else
    good "vault-1's seal token is valid and comes from the seal agent"
  fi
fi

echo "people"
if [ "$(vcry_container_state vcry-keycloak)" = running ]; then
  if curl -sf "http://127.0.0.1:$(vcry_conf VCRY_PORT_KEYCLOAK)/realms/vcry/.well-known/openid-configuration" >/dev/null 2>&1; then
    good "Keycloak realm vcry answers"
  else
    fix "Keycloak has no realm vcry" "make identity-bootstrap"
  fi
fi

echo "ports"
if "$VCRY_ROOT/scripts/ports-check.sh" >/dev/null 2>&1; then good "no port conflicts"; else fix "a port this stack needs is taken" "make ports-check, then override it in .env"; fi

echo
if [ "$problems" -eq 0 ]; then echo "doctor: nothing wrong found"; else
  echo "doctor: $problems problem(s)"
  exit 1
fi
