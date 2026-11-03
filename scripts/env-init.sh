#!/usr/bin/env bash
# scripts/env-init.sh — create .env from .env.example. Never overwrites a
# value that is already set.
set -euo pipefail
umask 077
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
env_file="$ROOT/.env"

[ -s "$env_file" ] || { cp "$ROOT/.env.example" "$env_file"; echo "env-init: created .env from .env.example"; }
chmod 600 "$env_file"
echo "env-init: .env is ready — set VAULT_LICENSE (or run make license)"
