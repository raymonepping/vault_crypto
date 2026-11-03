#!/usr/bin/env bash
# scripts/vault-wait.sh <node> <reachable|unsealed|active>
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
vault_node "${1:?node}"
vault_wait "${2:?state}" 60
echo "$1: ${2}"
