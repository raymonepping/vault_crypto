#!/usr/bin/env bash
# scripts/bootstrap.sh — first run, from zero to verified. Idempotent.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VCRY_ROOT"

log() { printf '\033[1m[bootstrap]\033[0m %s\n' "$*"; }
run() { log "$*"; "$VCRY_ROOT/scripts/$1.sh" "${@:2}"; }

log "Step 1/14: Podman pre-flight"
run podman-check

log "Step 2/14: Network"
run network

log "Step 3/14: TLS — lab CA + listener certificate"
run gen-certs

log "Step 4/14: Vault — initialise vault-s (Shamir) and vault-1 (Transit auto-unseal)"
run vault-bootstrap

log "Step 5/14: Terraform — vault-seal (AppRoles on vault-s)"
"$VCRY_ROOT/scripts/tf.sh" vault-seal apply

log "Step 6/14: Rotator credentials — seal plane"
"$VCRY_ROOT/scripts/rotator-bootstrap.sh" seal

log "Step 7/14: Seal plane — rotator + agent"
run seal-up
run vault-recreate

log "Step 8/14: Probe — prove every Vault 2.2 call the rooms use (docs/capabilities.md)"
run probe-2.2

log "Step 9/14: Terraform — vault-platform (AppRoles, policies) and vault-crypto (both CA chains, transit, transform)"
"$VCRY_ROOT/scripts/tf.sh" vault-platform apply
"$VCRY_ROOT/scripts/tf.sh" vault-crypto apply

log "Step 10/14: Demo state — the Transit keys whose algorithm the rooms change"
run demo-seed

log "Step 11/14: Identity — OpenLDAP + Keycloak, secrets in Vault KV"
run identity-up
"$VCRY_ROOT/scripts/compose.sh" identity --profile init up ldap-bootstrap keycloak-bootstrap
"$VCRY_ROOT/scripts/compose.sh" identity --profile init rm -f ldap-bootstrap keycloak-bootstrap >/dev/null

log "Step 12/14: Terraform — vault-identity (jwt + LDAP auth, human policies, groups)"
"$VCRY_ROOT/scripts/tf.sh" vault-identity apply

log "Step 13/14: Rotator credentials — app plane"
"$VCRY_ROOT/scripts/rotator-bootstrap.sh" app

log "Step 14/14: App — build images and start the stack"
run app-build
run app-up

log "Verifying..."
run verify

log "Done. vault_crypto is up. Sign in: make identity-copy-password U=olga, then Sign in at the console."
log "Browser tests: make e2e-install && make test-ui"
"$VCRY_ROOT/scripts/app-up.sh" || true   # print the URLs again
