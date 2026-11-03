#!/bin/sh
# scripts/network.sh — create the shared network if it does not exist.
set -eu
podman network exists vcry-internal || podman network create vcry-internal >/dev/null
