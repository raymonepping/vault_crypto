#!/usr/bin/env bash
# scripts/trust-root.sh add|remove — put Vault's pki-classic-root in (or take it out
# of) the macOS System keychain, so browsers accept the web UI without a
# warning. Asks for sudo. Only this lab's root is touched, matched by its
# SHA-1 fingerprint.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

[ "$(uname -s)" = Darwin ] || {
  echo "trust-root: macOS only; import pki-classic-root by hand on this OS" >&2
  exit 1
}
KEYCHAIN=/Library/Keychains/System.keychain
vault_node vault-1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -sf --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/pki-classic-root/ca/pem" >"$tmp/root.pem" ||
  {
    echo "trust-root: cannot read pki-classic-root from vault-1 (make vault-up)" >&2
    exit 1
  }
sha1=$(openssl x509 -in "$tmp/root.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)

case "${1:-}" in
add)
  if security find-certificate -a -Z -c "Vault Crypto Lab Classic Root CA" "$KEYCHAIN" 2>/dev/null | grep -q "$sha1"; then
    echo "trust-root: this pki-classic-root is already trusted"
  else
    echo "trust-root: adding Vault Crypto Lab Classic Root CA ($sha1) to the System keychain — sudo will ask"
    sudo security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN" "$tmp/root.pem"
    echo "trust-root: done. Restart the browser, then open https://localhost:$(vcry_conf VCRY_PORT_WEB)/"
  fi
  ;;
remove)
  if security find-certificate -a -Z -c "Vault Crypto Lab Classic Root CA" "$KEYCHAIN" 2>/dev/null | grep -q "$sha1"; then
    sudo security delete-certificate -Z "$sha1" "$KEYCHAIN"
    echo "trust-root: removed"
  else
    echo "trust-root: this pki-classic-root is not in the System keychain"
  fi
  ;;
*)
  echo "Usage: $0 add|remove" >&2
  exit 64
  ;;
esac
