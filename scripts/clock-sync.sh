#!/usr/bin/env bash
# scripts/clock-sync.sh — bring the Podman VM's clock back to the host's.
# No-op on Linux.
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo "clock-sync: not a Podman VM host; nothing to do"; exit 0; }
skew() { echo $(( $(date +%s) - $(podman machine ssh date +%s | tr -d '\r' | tail -1) )); }
before=$(skew)
if [ "${before#-}" -le 2 ]; then echo "clock-sync: VM clock is within ${before#-}s of the host"; exit 0; fi
podman machine ssh 'sudo chronyc burst 4/4 >/dev/null; sleep 12; sudo chronyc makestep >/dev/null'
sleep 2
after=$(skew)
if [ "${after#-}" -gt 5 ]; then
  podman machine ssh "sudo date -u -s @$(date +%s)" >/dev/null
  podman machine ssh 'sudo chronyc reselect >/dev/null 2>&1 || true'
  sleep 1
  after=$(skew)
fi
echo "clock-sync: VM was ${before}s behind the host, now ${after}s"
[ "${after#-}" -le 5 ]
