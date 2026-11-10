#!/usr/bin/env bash
# scripts/seal-token-status.sh: each node's own seal token, as its site's seal
# Vault sees it. Prints accessor fingerprints and TTLs, never a token. Exit 1
# when any token is rejected or expires within a day.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

bad=0
printf '%-12s %-10s %-10s %-10s %s\n' NODE ACCESSOR TTL RENEW STATE
for site in $VBAL_SITES; do
  vault_node "seal-$site"
  vault_token "ansible-seal-$site"
  for node in $(site_nodes "$site"); do
    file="$VBAL_STATE/seal/$node"
    if [ ! -s "$file" ]; then
      printf '%-12s %-10s %-10s %-10s %s\n' "$node" - - - "MISSING (make seal-tokens)"
      bad=1
      continue
    fi
    # token=@file: the CLI reads the file itself, so the token never shows in ps.
    if info=$(vault write -format=json auth/token/lookup token=@"$file" 2>/dev/null); then
      ttl=$(jq -r '.data.ttl' <<<"$info")
      printf '%-12s %-10s %-10s %-10s %s\n' "$node" \
        "$(fingerprint "$(jq -r '.data.accessor' <<<"$info")")" "${ttl}s" \
        "$(jq -r 'if .data.renewable then "renewable" else "fixed" end' <<<"$info")" "accepted ($(jq -r '.data.policies | join(",")' <<<"$info"))"
      [ "$ttl" -gt 86400 ] || bad=1
    else
      printf '%-12s %-10s %-10s %-10s %s\n' "$node" - - - "REJECTED by seal-$site (make seal-token-rotate NODE=$node)"
      bad=1
    fi
  done
  unset VAULT_TOKEN
done
exit "$bad"
