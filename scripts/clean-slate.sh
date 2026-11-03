#!/usr/bin/env bash
# scripts/clean-slate.sh — remove this lab's containers and persistent volumes,
# and move credentials aside. Takes a backup first if possible.
# Asks for DELETE to be typed; CONFIRM=DELETE answers for scripts.
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VCRY_ROOT"

containers=$(podman ps -a --filter name=^vcry- --format '{{.Names}}')
volumes=$(podman volume ls -q --filter name=^vcry- || true)

echo "clean-slate will remove:"
echo "  containers: $(echo $containers)"
echo "  volumes:    $(echo $volumes)"
echo "and move init files, transit token, rotator credentials and Terraform state to .secrets/legacy/."
echo "TLS material and .env are kept."
answer=${CONFIRM:-}
if [ -z "$answer" ]; then
  printf 'Type DELETE to continue: '
  read -r answer
fi
[ "$answer" = DELETE ] || { echo "clean-slate: aborted, nothing changed."; exit 1; }

if [ "${SKIP_BACKUP:-0}" != 1 ] && [ "$(vcry_container_state vcry-vault-1)" = running ] && [ -s "$VCRY_STATE/vault-init.json" ]; then
  "$VCRY_ROOT/scripts/backup.sh" || {
    echo "clean-slate: backup failed; nothing removed. SKIP_BACKUP=1 to start over without one." >&2
    exit 1
  }
fi

for c in $containers; do podman rm -f "$c" >/dev/null && echo "clean-slate: removed container $c"; done
for v in $volumes; do podman volume rm "$v" >/dev/null && echo "clean-slate: removed volume $v"; done

legacy=".secrets/legacy/$(date +%Y-%m-%d)/clean-slate-$(date +%H%M%S)"
mkdir -p "$legacy"
for f in .secrets/vault/seal-init.json .secrets/vault/vault-init.json .secrets/vault/transit-token \
  .secrets/vault/rotator .secrets/vault/seal-rotator .secrets/vault/identity \
  .secrets/terraform/vault-seal.tfstate .secrets/terraform/vault-seal.tfstate.backup \
  .secrets/terraform/vault-platform.tfstate .secrets/terraform/vault-platform.tfstate.backup \
  .secrets/terraform/vault-crypto.tfstate .secrets/terraform/vault-crypto.tfstate.backup \
  .secrets/terraform/vault-identity.tfstate .secrets/terraform/vault-identity.tfstate.backup; do
  [ -e "$f" ] && mv "$f" "$legacy/" && echo "clean-slate: moved ${f#.secrets/} to ${legacy#.secrets/}/"
done
echo "clean-slate: done. Run: make bootstrap"
