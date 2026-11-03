#!/usr/bin/env bash
# scripts/bench.sh [samples] — prompt 09's measurements in one command.
#
# Recreates the API with its load counters on (VCRY_STATS=1), runs
# api/scripts/bench.js as olga, and recreates the API without counters
# afterwards, also when the benchmark fails. Prints no token or password.
# Changes state: the API restarts twice (in-memory demo history and console
# sessions are lost; people sign in again).
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VCRY_ROOT"

samples=${1:-20}
api="http://127.0.0.1:$(vcry_conf VCRY_PORT_API)"

wait_api() {
  local _
  for _ in $(seq 1 30); do
    curl -sf "$api/api/health" >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "bench: the API did not come back healthy (make doctor)" >&2
  return 1
}

restore() {
  echo "bench: restarting the API without counters"
  ./scripts/compose.sh app up -d --force-recreate api >/dev/null 2>&1
  wait_api
}
trap restore EXIT

echo "bench: restarting the API with counters (VCRY_STATS=1)"
VCRY_STATS=1 ./scripts/compose.sh app up -d --force-recreate api >/dev/null 2>&1
wait_api
API="$api" KC="http://127.0.0.1:$(vcry_conf VCRY_PORT_KEYCLOAK)" node api/scripts/bench.js "$samples"
