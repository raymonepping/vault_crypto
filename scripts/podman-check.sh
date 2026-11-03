#!/bin/sh
# scripts/podman-check.sh — verify Podman, its machine, the compose provider,
# the VM clock and available memory before anything is started.
set -eu

MIN_MEMORY_GIB=4
MAX_CLOCK_SKEW=30

command -v podman >/dev/null 2>&1 || {
  echo "ERROR: Podman is not installed or is not in PATH." >&2
  exit 1
}

echo "Podman client"
podman version --format '  version={{.Client.Version}} os={{.Client.OsArch}}'

if [ "$(uname -s)" = "Darwin" ]; then
  echo "Podman machine"
  podman machine list --format '  {{.Name}}: {{.Running}} (cpus={{.CPUs}}, memory={{.Memory}}, disk={{.DiskSize}})'
fi

podman info >/dev/null 2>&1 || {
  echo "ERROR: Cannot reach the Podman service. Start it with: podman machine start" >&2
  exit 1
}

podman info --format 'Podman server
  version={{.Version.Version}}
  platform={{.Host.OS}}/{{.Host.Arch}}
  rootless={{.Host.Security.Rootless}}'

echo "Compose provider"
podman compose version 2>/dev/null | sed 's/^/  /'

failed=0

mem_bytes=$(podman info --format '{{.Host.MemTotal}}')
mem_gib=$((mem_bytes / 1073741824))
echo "Memory"
if [ "$mem_gib" -lt "$MIN_MEMORY_GIB" ]; then
  echo "  ERROR: ${mem_gib} GiB available to Podman; at least ${MIN_MEMORY_GIB} GiB is needed." >&2
  failed=1
else
  echo "  ${mem_gib} GiB (minimum ${MIN_MEMORY_GIB})"
fi

if [ "$(uname -s)" = "Darwin" ]; then
  echo "VM clock"
  host_now=$(date +%s)
  if vm_now=$(podman machine ssh date +%s 2>/dev/null | tr -d '\r' | tail -1) && [ -n "$vm_now" ]; then
    skew=$((host_now - vm_now))
    [ "$skew" -lt 0 ] && skew=$((-skew))
    if [ "$skew" -gt "$MAX_CLOCK_SKEW" ]; then
      echo "  ERROR: VM clock differs from the host by ${skew}s (limit ${MAX_CLOCK_SKEW}s)." >&2
      echo "  Fix: make clock-sync" >&2
      failed=1
    else
      echo "  skew ${skew}s (limit ${MAX_CLOCK_SKEW}s)"
    fi
  else
    echo "  WARNING: could not read the VM clock (podman machine ssh failed)." >&2
  fi
fi

echo "Host tools"
for tool in vault terraform jq openssl curl; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "  $tool: $(command -v "$tool")"
  else
    echo "  ERROR: $tool not found in PATH" >&2
    failed=1
  fi
done

[ "$failed" -eq 0 ] || exit 1
echo "OK: vault_crypto can use Podman."
