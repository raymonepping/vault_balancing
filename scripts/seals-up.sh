#!/usr/bin/env bash
# scripts/seals-up.sh: phase 1 (make seals-up). The network, then every site's
# seal Vault (Shamir, Raft). Sealed or uninitialised is fine here: phase
# seal-init initialises and unseals them.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
openssl verify -CAfile vault-tls/ca-chain.pem vault-tls/vault.crt >/dev/null 2>&1 || die "seals-up: vault-tls/vault.crt does not verify: run make gen-certs"
[ -s .secrets/vault/vault.hclic ] || die "seals-up: no licence at .secrets/vault/vault.hclic: run make license"
./scripts/network.sh
for site in $VBAL_SITES; do
  ./scripts/compose.sh "$site" up -d seal >/dev/null
done
for site in $VBAL_SITES; do
  vault_node "seal-$site"
  vault_wait reachable 45
  state=$(vault_json)
  echo "seals-up: seal-$site answers (initialized=$(jq -r .initialized <<<"$state"), sealed=$(jq -r .sealed <<<"$state"))"
done
