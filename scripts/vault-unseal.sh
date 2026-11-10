#!/usr/bin/env bash
# scripts/vault-unseal.sh <site>: idempotent unseal of that site's seal Vault
# (Shamir 1/1). Its nodes unseal themselves through its Transit key. Every
# start path calls this before a site's nodes start (gotcha 20).
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

site=${1:?Usage: vault-unseal.sh <site>}
site_exists "$site"
vault_node "seal-$site"
INIT_FILE="$VBAL_STATE/seal-$site-init.json"
[ -s "$INIT_FILE" ] || die "unseal: .secrets/vault/seal-$site-init.json not found: run make lab first (phase seal-init)"
vault_wait reachable 30
state=$(vault_json) || die "unseal: seal-$site unreachable at $VAULT_ADDR"
jq -e '.initialized' <<<"$state" >/dev/null || die "unseal: seal-$site reports uninitialized but saved keys exist: its volume was lost."
if jq -e '.sealed | not' <<<"$state" >/dev/null; then
  echo "unseal: seal-$site is already unsealed"
  exit 0
fi
unseal_key=$(jq -er '.unseal_keys_b64[0]' "$INIT_FILE") || die "unseal: could not read the unseal key from .secrets/vault/seal-$site-init.json"
echo "unseal: seal-$site is sealed, unsealing"
# The key goes to the API in a JSON body on curl's stdin: printf is a shell
# builtin, so the key is on no command line (ps).
code=$(printf '{"key":"%s"}' "$unseal_key" | curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$VAULT_CACERT" \
  -X PUT --data-binary @- "$VAULT_ADDR/v1/sys/unseal" || true)
unset unseal_key
[ "$code" = 200 ] || die "unseal: seal-$site answered HTTP $code to sys/unseal"
vault_json | jq -e '.sealed | not' >/dev/null || die "unseal: seal-$site still reports sealed: the saved key does not match this storage"
echo "unseal: seal-$site is unsealed"
