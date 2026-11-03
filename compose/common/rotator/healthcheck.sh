#!/bin/sh
# Healthy when every target role has a role-id, secret-id and metadata on disk.
set -eu
for role in $TARGET_ROLES; do
  for f in role-id secret-id metadata.json; do [ -s "/run/approle/$role/$f" ] || exit 1; done
done
