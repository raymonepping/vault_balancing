#!/usr/bin/env bash
# scripts/trust-root.sh add|remove: put the lab CA in (or take it out of) the
# macOS System keychain, so browsers accept the console without a warning.
# Asks for sudo. Only this lab's CA is touched, matched by its SHA-1
# fingerprint.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

[ "$(uname -s)" = Darwin ] || {
  echo "trust-root: macOS only; import vault-tls/ca-chain.pem by hand on this OS" >&2
  exit 1
}
KEYCHAIN=/Library/Keychains/System.keychain
CA="$VBAL_ROOT/vault-tls/ca-chain.pem"
[ -s "$CA" ] || {
  echo "trust-root: vault-tls/ca-chain.pem is missing (make gen-certs)" >&2
  exit 1
}
NAME=$(openssl x509 -in "$CA" -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= //p')
sha1=$(openssl x509 -in "$CA" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)
trusted() { security find-certificate -a -Z -c "$NAME" "$KEYCHAIN" 2>/dev/null | grep -q "$sha1"; }

case "${1:-}" in
add)
  if trusted; then
    echo "trust-root: the lab CA is already trusted"
  else
    echo "trust-root: adding $NAME ($sha1) to the System keychain; sudo will ask"
    sudo security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN" "$CA"
    echo "trust-root: done. Restart the browser, then open https://localhost:$(vbal_conf VBAL_PORT_WEB)/"
  fi
  ;;
remove)
  if trusted; then
    sudo security delete-certificate -Z "$sha1" "$KEYCHAIN"
    echo "trust-root: removed"
  else
    echo "trust-root: the lab CA is not in the System keychain"
  fi
  ;;
*)
  echo "Usage: $0 add|remove" >&2
  exit 64
  ;;
esac
