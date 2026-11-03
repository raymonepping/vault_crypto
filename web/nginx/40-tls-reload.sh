#!/bin/sh
# 40-tls-reload.sh — reload nginx whenever tls-agent writes a new certificate.
#
# tls-agent renders leaf + issuing CA + key into ONE file with an atomic
# rename, so a changed checksum always means a complete new pair. `nginx -t`
# guards the reload anyway: a broken file never takes the server down.
CERT=/etc/nginx/tls/web.pem
(
  last=$(cksum <"$CERT" 2>/dev/null)
  while sleep 5; do
    cur=$(cksum <"$CERT" 2>/dev/null) || continue
    [ "$cur" = "$last" ] && continue
    if nginx -t -q 2>/dev/null; then
      nginx -s reload && echo "[tls-reload] $(date -u +%FT%TZ) new certificate from tls-agent — nginx reloaded"
      last=$cur
    else
      echo "[tls-reload] $(date -u +%FT%TZ) certificate changed but nginx -t failed; keeping the current one" >&2
    fi
  done
) &
