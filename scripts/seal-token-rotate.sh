#!/usr/bin/env bash
# scripts/seal-token-rotate.sh <node>: give one node a new seal token from its
# site's seal Vault, recreate only that node, wait until it is unsealed again,
# then revoke the old token. The other nodes are untouched: each has its own.
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

node=${1:?Usage: make seal-token-rotate NODE=vault-<site>-<n>}
[[ "$node" == vault-*-* ]] || die "seal-token-rotate: $node is not a cluster node (vault-<site>-<n>)"
site=$(site_of "$node")
site_exists "$site"
file="$VBAL_STATE/seal/$node"

vault_node "seal-$site"
vault_token "ansible-seal-$site"
old_accessor=""
if [ -s "$file" ]; then
  # token=@file: the CLI reads the file itself, so the token never shows in ps.
  old_accessor=$(vault write -format=json auth/token/lookup token=@"$file" 2>/dev/null | jq -r '.data.accessor' || true)
fi
new=$(vault write -format=json -f auth/token/create/autounseal display_name="vbal-seal-$node")
new_accessor=$(jq -r '.auth.accessor' <<<"$new")
# Write in place: the file is a single-file bind mount (keep the inode, gotcha 4).
: >"$file"
jq -j '.auth.client_token' <<<"$new" >"$file"
unset new VAULT_TOKEN
echo "seal-token-rotate: $node has a new seal token (accessor $(fingerprint "$new_accessor"))"

"$VBAL_ROOT/scripts/compose.sh" "$site" up -d --force-recreate "vault-${node##*-}" >/dev/null 2>&1
vault_node "$node"
vault_wait unsealed 90
echo "seal-token-rotate: $node restarted and unsealed with the new token"

if [ -n "$old_accessor" ] && [ "$old_accessor" != null ]; then
  vault_node "seal-$site"
  vault_token "ansible-seal-$site"
  vault write -f auth/token/revoke-accessor accessor="$old_accessor" >/dev/null 2>&1 || true
  echo "seal-token-rotate: old token revoked (accessor $(fingerprint "$old_accessor"))"
fi
