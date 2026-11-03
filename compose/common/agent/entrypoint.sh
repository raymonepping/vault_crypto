#!/bin/sh
# compose/common/agent/entrypoint.sh — Vault Agent with a token watchdog.
# Used by both planes: the seal agent (vault-s) and the app agent (vault-1).
# From Project Durin, via vault_reference and secret_rotation.
#
# Vault Agent's token can die without the agent noticing. This watchdog asks
# Vault about the sink token every WATCHDOG_INTERVAL seconds; after
# WATCHDOG_MAX_FAILURES consecutive rejections it stops the agent and exits
# non-zero, so `restart: on-failure` starts a fresh container.
set -eu
umask 027

: "${TOKEN_FILE:?TOKEN_FILE is required}"
: "${WATCHDOG_GRACE:=30}"
: "${WATCHDOG_INTERVAL:=20}"
: "${WATCHDOG_MAX_FAILURES:=3}"
log() { echo "[agent:${AGENT_NAME:-?}] $*"; }

: "${APPROLE_DIR:?APPROLE_DIR is required}"
log "waiting for role-id and secret-id in $APPROLE_DIR..."
n=0
while [ ! -s "$APPROLE_DIR/role-id" ] || [ ! -s "$APPROLE_DIR/secret-id" ]; do
  n=$((n + 1))
  [ "$n" -ge 120 ] && { log "timed out waiting for AppRole files — is the rotator healthy? (make agents-status)" >&2; exit 1; }
  sleep 1
done

rm -f "$TOKEN_FILE"

vault agent -config=/vault/agent/config.hcl &
AGENT=$!
trap 'kill -TERM "$AGENT" 2>/dev/null; wait "$AGENT" 2>/dev/null; exit 0' TERM INT
nap() { sleep "$1" & wait $! || true; }

nap "$WATCHDOG_GRACE"
fails=0
while kill -0 "$AGENT" 2>/dev/null; do
  if [ -s "$TOKEN_FILE" ]; then
    if out=$(VAULT_TOKEN=$(cat "$TOKEN_FILE") vault token lookup -format=json 2>&1); then
      fails=0
    elif printf '%s' "$out" | grep -qiE "permission denied|invalid token|bad token"; then
      fails=$((fails + 1))
      log "watchdog: Vault rejected the agent's token ($fails/$WATCHDOG_MAX_FAILURES)"
    fi
  fi
  if [ "$fails" -ge "$WATCHDOG_MAX_FAILURES" ]; then
    log "watchdog: token is dead and the agent has not re-authenticated — exiting so the container restarts"
    kill -TERM "$AGENT" 2>/dev/null || true
    wait "$AGENT" 2>/dev/null || true
    exit 1
  fi
  nap "$WATCHDOG_INTERVAL"
done
wait "$AGENT"
exit $?
