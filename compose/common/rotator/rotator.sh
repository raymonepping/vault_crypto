#!/bin/sh
# compose/common/rotator/rotator.sh — AppRole secret-id rotator.
#
# Keeps a valid secret-id on disk for every role in TARGET_ROLES, each in its
# own directory under /run/approle/<role>/, so the matching Vault Agent can
# (re)authenticate at any time. From Project Durin, via vault_reference and
# secret_rotation.
#
# Decides on VAULT'S OWN answer: rotates when Vault says the secret-id is
# invalid or has less than 1/ROTATE_BELOW_FRACTION of its life left.
set -eu

: "${VAULT_ADDR:?VAULT_ADDR is required}"
: "${VAULT_CACERT:=/vault/tls/ca-chain.pem}"
: "${TARGET_ROLES:?TARGET_ROLES is required (space separated)}"
: "${ROTATOR_CREDS_DIR:=/run/rotator}"
: "${CHECK_INTERVAL_SECONDS:=43200}"
: "${ROTATE_BELOW_FRACTION:=3}"
: "${WARN_IF_SHORTER_THAN:=7776000}"
export VAULT_ADDR VAULT_CACERT
[ -n "${VAULT_TLS_SERVER_NAME:-}" ] && export VAULT_TLS_SERVER_NAME

umask 077
log() { echo "[rotator] $(date -u +'%Y-%m-%dT%H:%M:%SZ') $*"; }

to_epoch() { date -u -d "$(printf '%s' "$1" | cut -c1-19 | tr 'T' ' ')" +%s 2>/dev/null || echo 0; }

get_token() {
  vault write -field=token auth/approle/login \
    role_id="$(cat "$ROTATOR_CREDS_DIR/role-id")" secret_id="$(cat "$ROTATOR_CREDS_DIR/secret-id")"
}

lookup_field() {
  VAULT_TOKEN="$1" vault write -field="$4" "auth/approle/role/$2/secret-id/lookup" secret_id="$3" 2>/dev/null
}

write_atomic() {
  printf '%s' "$2" >"$1.tmp" && mv "$1.tmp" "$1" && chmod 600 "$1"
}

rotate() {
  token=$1 role=$2 dir="/run/approle/$2"
  old="" old_acc=""
  [ -s "$dir/secret-id" ] && old=$(cat "$dir/secret-id")
  [ -n "$old" ] && old_acc=$(lookup_field "$token" "$role" "$old" secret_id_accessor || true)

  role_id=$(VAULT_TOKEN="$token" vault read -field=role_id "auth/approle/role/$role/role-id")
  new=$(VAULT_TOKEN="$token" vault write -field=secret_id -f "auth/approle/role/$role/secret-id")
  [ -n "$new" ] && [ "$new" != null ] || { log "ERROR: no secret-id returned for $role"; return 1; }
  acc=$(lookup_field "$token" "$role" "$new" secret_id_accessor || echo unknown)
  exp=$(lookup_field "$token" "$role" "$new" expiration_time || echo "")

  write_atomic "$dir/role-id" "$role_id"
  write_atomic "$dir/secret-id" "$new"
  now=$(date +%s)
  write_atomic "$dir/metadata.json" "{\"role_name\":\"$role\",\"secret_id_accessor\":\"$acc\",\"created_at_epoch\":$now,\"expiration_time\":\"$exp\",\"last_rotation_utc\":\"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\"}"

  if [ -n "$old_acc" ] && [ "$old_acc" != "$acc" ]; then
    if VAULT_TOKEN="$token" vault write "auth/approle/role/$role/secret-id-accessor/destroy" secret_id_accessor="$old_acc" >/dev/null 2>&1; then
      log "$role: destroyed the replaced secret-id (accessor ${old_acc%%-*}…)"
    else
      log "$role: WARNING could not destroy the replaced secret-id; it will expire on its own"
    fi
  fi

  life=$(($(to_epoch "$exp") - now))
  if [ "$life" -gt 0 ] && [ "$life" -lt $((WARN_IF_SHORTER_THAN - 3600)) ]; then
    log "$role: WARNING Vault issued a secret-id that lives $((life / 86400)) days — something above the role caps it (vault read sys/mounts/auth/approle/tune)"
  fi
  log "$role: rotated secret-id (expires ${exp:-never})"
}

needs_rotation() {
  token=$1 role=$2 dir="/run/approle/$2"
  [ -s "$dir/secret-id" ] && [ -s "$dir/role-id" ] && [ -s "$dir/metadata.json" ] || { log "$role: no secret-id on disk — issuing"; return 0; }
  [ -e "$dir/rotate-now" ] && { rm -f "$dir/rotate-now"; log "$role: rotation requested"; return 0; }
  cur=$(cat "$dir/secret-id")
  exp=$(lookup_field "$token" "$role" "$cur" expiration_time || echo "")
  cre=$(lookup_field "$token" "$role" "$cur" creation_time || echo "")
  [ -n "$exp" ] || { log "$role: Vault does not recognise the current secret-id — rotating"; return 0; }
  [ "$exp" = "0001-01-01T00:00:00Z" ] && return 1
  now=$(date +%s); e=$(to_epoch "$exp"); c=$(to_epoch "$cre")
  left=$((e - now)); life=$((e - c)); [ "$life" -gt 0 ] || life=$WARN_IF_SHORTER_THAN
  if [ "$left" -lt $((life / ROTATE_BELOW_FRACTION)) ]; then
    log "$role: $((left / 3600)) h left of a $((life / 86400))-day life — rotating"
    return 0
  fi
  return 1
}

pass() {
  token=$(get_token) || { log "WARNING: rotator login failed"; return 1; }
  rc=0
  for role in $TARGET_ROLES; do
    mkdir -p "/run/approle/$role"
    if needs_rotation "$token" "$role"; then rotate "$token" "$role" || rc=1; fi
  done
  VAULT_TOKEN="$token" vault token revoke -self >/dev/null 2>&1 || true
  date +%s >/tmp/last-pass
  return $rc
}

log "starting; roles: $TARGET_ROLES"
until vault status >/dev/null 2>&1; do
  log "waiting for Vault at $VAULT_ADDR to be unsealed..."
  sleep 3
done

while true; do
  if pass; then nap=$CHECK_INTERVAL_SECONDS; else log "pass failed; retrying in 30s"; nap=30; fi
  waited=0
  while [ "$waited" -lt "$nap" ]; do
    sleep 5; waited=$((waited + 5))
    for role in $TARGET_ROLES; do [ -e "/run/approle/$role/rotate-now" ] && waited=$nap; done
  done
done
