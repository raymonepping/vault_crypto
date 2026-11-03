#!/usr/bin/env bash
# scripts/vault-bootstrap.sh — bring vault-s and vault-1 into existence.
# Host-side and idempotent: safe to re-run at any time.
#
# Creates only what must exist before Terraform runs: init, unseal, the Transit
# `autounseal` key + policy + token on vault-s, and audit on each.
# Namespaces, Transit engines, PKI and AppRoles on vault-1 are Terraform's job.
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VCRY_ROOT"

for tool in vault jq podman openssl curl; do
  command -v "$tool" >/dev/null || {
    echo "Missing command: $tool" >&2
    exit 127
  }
done
openssl verify -CAfile vault-tls/ca-chain.pem vault-tls/vault.crt >/dev/null 2>&1 || {
  echo "vault-tls/vault.crt does not verify — run make gen-certs" >&2
  exit 1
}
# ENT licence must be present.
[ -s .secrets/vault/vault.hclic ] || {
  echo "Vault Enterprise licence not found at .secrets/vault/vault.hclic — run make license" >&2
  exit 1
}
mkdir -p "$VCRY_STATE"
chmod 700 .secrets "$VCRY_STATE"

mkdir "$VCRY_STATE/bootstrap.lock" 2>/dev/null || {
  echo "Bootstrap lock exists (.secrets/vault/bootstrap.lock). Check for a running bootstrap." >&2
  exit 1
}
trap 'rmdir "$VCRY_STATE/bootstrap.lock"' EXIT

log() { echo "[bootstrap] $*"; }
compose() { "$VCRY_ROOT/scripts/compose.sh" "$@"; }

# Four-case idempotency table: init file vs storage state.
initialize() {
  local cluster=$1 state tmp file="$VCRY_STATE/$1-init.json"
  shift
  state=$(vault_json)
  if jq -e '.initialized' <<<"$state" >/dev/null; then
    [ -s "$file" ] || {
      echo "$cluster is initialized but ${file#"$VCRY_ROOT"/} is missing. Restore from backup." >&2
      return 1
    }
    log "$cluster: already initialized"
  else
    [ ! -e "$file" ] || {
      echo "$cluster has saved credentials but no initialized storage: volume was lost. Restore the volume or move the file to .secrets/legacy/." >&2
      return 1
    }
    tmp=$(mktemp "$VCRY_STATE/$cluster-init.pending.XXXXXX")
    vault operator init -format=json "$@" >"$tmp"
    jq -e '.root_token' "$tmp" >/dev/null
    mv "$tmp" "$file"
    log "$cluster: initialized; credentials saved to ${file#"$VCRY_ROOT"/}"
  fi
}

enable_audit() {
  if ! vault audit list -format=json 2>/dev/null | jq -e 'has("file/")' >/dev/null; then
    vault audit enable file file_path=/vault/audit/vault-audit.log mode=0600 >/dev/null
    log "$1: audit device enabled"
  fi
}

"$VCRY_ROOT/scripts/network.sh"

# ── vault-s ──────────────────────────────────────────────────────────────────
log "starting vault-s"
compose seal up -d vault-s
vault_node vault-s
vault_wait reachable
initialize seal -key-shares=1 -key-threshold=1
if vault_json | jq -e '.sealed' >/dev/null; then
  key=$(vault_init_field seal '.unseal_keys_b64[0]')
  vault operator unseal "$key" >/dev/null
  unset key
  log "seal: unsealed"
fi
vault_wait active
vault_root seal
if ! vault secrets list -format=json | jq -e 'has("transit/")' >/dev/null; then
  vault secrets enable transit >/dev/null
  log "seal: transit engine enabled"
fi
vault read transit/keys/autounseal >/dev/null 2>&1 || {
  vault write -f transit/keys/autounseal >/dev/null
  log "seal: transit key 'autounseal' created"
}
vault policy write autounseal vault/policies/autounseal.hcl >/dev/null
enable_audit seal

# Transit seal token: periodic and orphan.
token_valid=false
if [ -s "$VCRY_STATE/transit-token" ]; then
  token=$(cat "$VCRY_STATE/transit-token")
  if VAULT_TOKEN="$token" vault token lookup >/dev/null 2>&1; then token_valid=true; fi
  unset token
fi
if [ "$token_valid" = false ]; then
  tmp=$(mktemp "$VCRY_STATE/transit-token.pending.XXXXXX")
  vault token create -orphan -policy=autounseal -period=720h \
    -display-name=vcry-auto-unseal -field=token >"$tmp"
  test -s "$tmp"
  cat "$tmp" >"$VCRY_STATE/transit-token"
  rm -f "$tmp"
  log "seal: new transit token issued"
fi
unset VAULT_TOKEN

# ── vault-1 ──────────────────────────────────────────────────────────────────
ensure_seal_token_volume
log "starting vault-1"
if [ "$token_valid" = false ]; then
  compose vault up -d --force-recreate vault-1
else
  compose vault up -d vault-1
fi
vault_node vault-1
vault_wait reachable
initialize vault -recovery-shares=1 -recovery-threshold=1
vault_wait active
log "vault: vault-1 unsealed and active"
vault_root vault
enable_audit vault
unset VAULT_TOKEN

"$VCRY_ROOT/scripts/vault-status.sh" || true
echo 'Ready. Run `make tf-all` then `make rotator-bootstrap` then `make app-up` and finally `make verify`.'
