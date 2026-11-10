#!/usr/bin/env bash
# scripts/identity-secrets.sh: the identity stack's secrets (D15), generated
# once into .secrets/identity/ (0700, files 0600), never overwritten, never
# printed. Not in Vault on purpose: identity must work while a site is dead.
#   ldap-admin-password, keycloak-admin-password, console-client-secret,
#   runner-secret (the API to the host runner), system/keycloak-bind,
#   users/{vera,oscar,ada}
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
d="$VBAL_ROOT/.secrets/identity"
mkdir -p "$d/users" "$d/system"
chmod 700 "$d" "$d/users" "$d/system"
made=0
for f in ldap-admin-password keycloak-admin-password console-client-secret runner-secret system/keycloak-bind users/vera users/oscar users/ada; do
  [ -s "$d/$f" ] && continue
  openssl rand -base64 24 | tr -d '\n/+=' >"$d/$f"
  chmod 600 "$d/$f"
  made=$((made + 1))
done
echo "identity-secrets: $made generated, the rest kept (.secrets/identity/)"
