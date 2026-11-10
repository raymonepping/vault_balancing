#!/usr/bin/env bash
# scripts/identity-up.sh (make identity-up): OpenLDAP and Keycloak (D15), the
# directory loaded and the realm set up by two one-shots, which are removed
# after a successful start (a failed one keeps its container and logs).
# Idempotent: a re-run changes nothing that is already in place.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
mkdir -p "$BUILD_DIR/logs"
./scripts/identity-secrets.sh
./scripts/network.sh
./scripts/compose.sh identity up -d openldap keycloak >/dev/null

one_shot() { # <service> <container>
  # A container kept by an earlier failed attempt would block the name; its
  # output is in .build/logs/identity-<service>.log.
  podman container rm -f "$2" >/dev/null 2>&1 || true
  ./scripts/compose.sh identity --profile init run --name "$2" "$1" >"$BUILD_DIR/logs/identity-$1.log" 2>&1 || {
    tail -15 "$BUILD_DIR/logs/identity-$1.log" >&2
    die "identity-up: $1 failed; its container $2 is kept (podman logs $2)"
  }
}
one_shot ldap-bootstrap vbal-ldap_bootstrap
podman container rm vbal-ldap_bootstrap >/dev/null
./scripts/ldap-acl.sh
one_shot keycloak-bootstrap vbal-keycloak_bootstrap
podman container rm vbal-keycloak_bootstrap >/dev/null

grep -E 'LDAP fixture|LDAP passwords' "$BUILD_DIR/logs/identity-ldap-bootstrap.log" | sed 's/^/identity-up: /'
echo "identity-up: realm balancing ready at http://localhost:$(vbal_conf VBAL_PORT_KEYCLOAK) (one-shots removed)"
