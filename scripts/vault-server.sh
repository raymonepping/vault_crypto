#!/bin/sh
# scripts/vault-server.sh — entrypoint of both Vault server containers.
set -eu

# The Transit seal token is delivered as a file, never as an environment
# variable in a compose file. vault-s has neither file (Shamir seal).
# It is read once, here: a replaced token is used from the next start on.
#
#   /run/secrets/seal/transit-token  seal agent sink (preferred)
#   /run/secrets/transit-token       bootstrap token (fallback)
SEAL_ADDR="https://vault-s:8200"
CA=/vault/config/tls/ca-chain.pem

pick_token() {
  if [ -s /run/secrets/seal/transit-token ]; then
    t=$(cat /run/secrets/seal/transit-token)
    if out=$(VAULT_ADDR=$SEAL_ADDR VAULT_CACERT=$CA VAULT_TOKEN=$t vault token lookup 2>&1); then
      echo "[vault-server] seal token: seal agent sink" >&2
      printf '%s' "$t"
      return 0
    fi
    if printf '%s' "$out" | grep -qiE "permission denied|invalid token|bad token"; then
      echo "[vault-server] the seal agent's token was REJECTED by vault-s; falling back to the bootstrap token" >&2
    else
      echo "[vault-server] seal token: seal agent sink (vault-s not reachable to verify)" >&2
      printf '%s' "$t"
      return 0
    fi
  fi
  if [ -s /run/secrets/transit-token ]; then
    echo "[vault-server] seal token: bootstrap file" >&2
    cat /run/secrets/transit-token
    return 0
  fi
  return 1
}

if [ -e /run/secrets/transit-token ] || [ -d /run/secrets/seal ]; then
  VAULT_TOKEN=$(pick_token) || {
    echo '[vault-server] no Transit seal token available; run make vault-bootstrap.' >&2
    exit 1
  }
  export VAULT_TOKEN
fi

mkdir -p /vault/file /vault/audit
touch /vault/audit/vault-audit.log
exec vault server -config=/vault/config/config.hcl
