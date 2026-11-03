#!/usr/bin/env bash
# scripts/backup.sh — everything needed to bring this lab back:
#
#   vault-s.snap  Raft snapshot of vault-s (holds the Transit key)
#   vault-1.snap  Raft snapshot of vault-1 (both CA chains, transit, transform, AppRoles)
#   secrets.tar   .secrets/{vault,terraform,tls}
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VCRY_ROOT"

dest="backups/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$dest"
chmod 700 backups "$dest"

for node in vault-s vault-1; do
  vault_node "$node"
  vault_root "$(vault_cluster_of "$node")"
  vault operator raft snapshot save "$dest/$node.snap"
  echo "backup: $node snapshot saved"
done
unset VAULT_TOKEN

tar -cf "$dest/secrets.tar" -C .secrets vault terraform tls 2>/dev/null ||
  tar -cf "$dest/secrets.tar" -C .secrets vault terraform tls
chmod 600 "$dest"/*
echo "backup: written to $dest/ ($(du -sh "$dest" | cut -f1))"
