#!/bin/sh
# scripts/compose.sh — thin Podman Compose wrapper for the vault_crypto stacks.
# Usage: compose.sh <stack> <compose arguments...>
#
# One compose project per stack (vcry-<stack>), all on the shared network
# vcry-internal. config/defaults.env is loaded first, .env second, so .env wins.
set -eu

STACKS="seal vault identity app publicca"

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <stack> <compose arguments...>" >&2
  echo "Stacks: $STACKS" >&2
  exit 64
fi

stack=$1
shift

case " $STACKS " in
*" $stack "*) ;;
*)
  echo "Unknown stack: $stack (known: $STACKS)" >&2
  exit 64
  ;;
esac

project_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
compose_file="$project_root/compose/$stack/compose.yaml"

if [ ! -f "$compose_file" ]; then
  echo "Stack '$stack' is not implemented yet: compose/$stack/compose.yaml is missing." >&2
  exit 66
fi

command -v podman >/dev/null 2>&1 || {
  echo "Podman is required but was not found in PATH." >&2
  exit 69
}

[ -f "$project_root/.env" ] || {
  echo "Missing .env — run: make env-init" >&2
  exit 66
}

# A Docker-era COMPOSE_FILE list in the user's shell must not leak in.
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME

run_compose() {
  podman compose \
    --project-name "vcry-$stack" \
    --project-directory "$project_root/compose/$stack" \
    --file "$compose_file" \
    --env-file "$project_root/config/defaults.env" \
    --env-file "$project_root/.env" \
    "$@"
}

if [ "${1:-}" != "up" ]; then
  run_compose "$@"
  exit $?
fi

log=$(mktemp)
trap 'rm -f "$log"' EXIT

status=0
run_compose "$@" >"$log" 2>&1 || status=$?
cat "$log"

# One retry on the known dependent-container race.
if [ "$status" -ne 0 ] && grep -qE 'dependent container|already in use' "$log"; then
  echo "[compose.sh] '$stack up' hit the known dependent-container race — retrying once" >&2
  status=0
  run_compose "$@" >"$log" 2>&1 || status=$?
  cat "$log"
fi

exit "$status"
