#!/usr/bin/env bash
# scripts/site-destroy.sh <site> (make site-destroy SITE=<site>): DESTRUCTIVE,
# the hard variant of a dead site. Removes that site's containers and volumes
# (its Raft data and audit logs) and moves its init files and seal tokens to
# .secrets/legacy/. The site comes back only through make lab (a new cluster,
# activated again). Type the site's id to confirm.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
site=${1:?Usage: make site-destroy SITE=<site>}
site_exists "$site"
answer=${CONFIRM:-}
if [ "$answer" != "$site" ]; then
  printf 'This removes every container and volume of %s (Raft data, audit logs). Type %s: ' "$site" "$site"
  read -r answer
fi
[ "$answer" = "$site" ] || { echo "Aborted."; exit 1; }
./scripts/compose.sh "$site" down -v --remove-orphans >/dev/null 2>&1 || true
legacy=".secrets/legacy/$(date -u +%Y%m%dT%H%M%SZ)-$site"
mkdir -p "$legacy"
for p in ".secrets/vault/seal-$site-init.json" ".secrets/vault/vault-$site-init.json" .secrets/vault/seal/vault-"$site"-* ".secrets/vault/tokens/tf-seal-$site" ".secrets/vault/tokens/ansible-seal-$site" ".secrets/terraform/seal-$site"; do
  [ -e "$p" ] && mv "$p" "$legacy/"
done
echo "site-destroy: $site removed; its credentials moved to $legacy. Rebuild it with make lab."
