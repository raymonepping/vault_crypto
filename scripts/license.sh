#!/usr/bin/env bash
# scripts/license.sh — install the Vault Enterprise licence.
#
# Usage:
#   license.sh                    read from .env VAULT_LICENSE variable
#   license.sh --status           check only (read-only)
#   license.sh LICENSE_FILE=path  install from a file
#
# The licence is written to .secrets/vault/vault.hclic (mode 0600) and the
# VAULT_LICENSE variable in .env is set to point to it. Containers read the
# file at start via the compose env var substitution.
set -euo pipefail
umask 077
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DEST="$ROOT/.secrets/vault/vault.hclic"

status_check() {
  if [ -s "$DEST" ]; then
    echo "license: .secrets/vault/vault.hclic present ($(wc -c <"$DEST" | tr -d ' ') bytes)"
  else
    echo "license: .secrets/vault/vault.hclic NOT present — run make license" >&2
    exit 1
  fi
}

case "${1:-}" in
--status)
  status_check
  exit 0
  ;;
esac

mkdir -p "$(dirname "$DEST")"
chmod 700 "$ROOT/.secrets" "$(dirname "$DEST")"

# Priority: explicit LICENSE_FILE arg, then VAULT_LICENSE env var in .env.
src_file="${LICENSE_FILE:-}"
if [ -z "$src_file" ]; then
  val=$(grep -E '^VAULT_LICENSE=' "$ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  if [ -n "$val" ] && [ -f "$val" ]; then
    src_file="$val"
  elif [ -n "$val" ] && [ ${#val} -gt 100 ]; then
    # It's the raw licence string, not a path.
    printf '%s' "$val" >"$DEST"
    chmod 600 "$DEST"
    echo "license: installed from VAULT_LICENSE string in .env"
    status_check
    exit 0
  fi
fi

[ -n "$src_file" ] && [ -f "$src_file" ] || {
  echo "license: no licence source found. Set VAULT_LICENSE in .env to the licence string or a path." >&2
  exit 1
}
install -m 0600 "$src_file" "$DEST"
echo "license: installed from $src_file"
status_check
