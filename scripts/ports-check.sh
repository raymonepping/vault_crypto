#!/usr/bin/env bash
# scripts/ports-check.sh — report host ports this stack wants that something
# else already holds. Read-only.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

names=$(grep -hoE '^VCRY_PORT_[A-Z0-9_]+' "$VCRY_ROOT/config/defaults.env" "$VCRY_ROOT/.env" 2>/dev/null | sort -u)
published=$(podman ps --format '{{.Names}} {{.Ports}}' 2>/dev/null || true)
conflicts=0
for name in $names; do
  port=$(vcry_conf "$name")
  [ -n "$port" ] || continue
  holder=$(awk -v p=":$port->" 'index($0, p) {print $1}' <<<"$published" | head -1)
  if [ -n "$holder" ]; then
    case "$holder" in
    vcry-*) printf '  %-22s %-6s in use by %s (this stack)\n' "$name" "$port" "$holder" ;;
    *) printf '  %-22s %-6s CONFLICT: held by container %s\n' "$name" "$port" "$holder"; conflicts=$((conflicts + 1)) ;;
    esac
  elif lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    proc=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1" (pid "$2")"}')
    printf '  %-22s %-6s CONFLICT: held by %s\n' "$name" "$port" "$proc"
    conflicts=$((conflicts + 1))
  else
    printf '  %-22s %-6s free\n' "$name" "$port"
  fi
done
if [ "$conflicts" -gt 0 ]; then
  echo "$conflicts port(s) taken. Override them in .env (see config/defaults.env)." >&2
  exit 1
fi
