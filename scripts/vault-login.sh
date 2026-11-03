#!/usr/bin/env bash
# scripts/vault-login.sh — print the export line that points your shell's
# vault CLI at a node. Usage: make vault-login NODE=vault-s|vault-1
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
node=${1:-vault-1}
vault_node "$node"
echo "export VAULT_ADDR=$VAULT_ADDR VAULT_CACERT=$VAULT_CACERT"
