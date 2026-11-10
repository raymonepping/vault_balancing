#!/usr/bin/env bash
# scripts/license-features.sh: which licensed features this lab needs, and
# whether the cluster's autoloaded licence has them. Read-only. Prints feature
# names and the expiry date, never the licence itself. A phase of make lab
# right after bootstrap: the first moment a cluster can answer, so a licence
# without replication stops the build before replication is attempted.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

vault_primary >/dev/null || die "license-features: no primary site answers"
vault_token ansible-platform
status=$(vault read -format=json sys/license/status)
version=$(vault_json | jq -r .version)
unset VAULT_TOKEN
features=$(jq -r '.data.autoloaded.features[]' <<<"$status")

echo "cluster licence: expires $(jq -r '.data.autoloaded.expiration_time' <<<"$status" | cut -c1-10), Vault $version"
case "$version" in *+ent*) ;; *)
  echo "  NOT Enterprise: replication and namespaces need it." >&2
  exit 1
  ;;
esac
missing=0
has() { grep -qxF "$1" <<<"$features"; }
row() { # <area> <needs> [feature]: "edition" rows need Enterprise only
  local got
  if [ -z "${3:-}" ]; then
    got="yes (Enterprise $version)"
  elif has "$3"; then
    got="yes"
  else
    got="NO"
    missing=1
  fi
  printf '  %-28s %-34s %s\n' "$1" "$2" "$got"
}
printf '  %-28s %-34s %s\n' AREA NEEDS LICENSED
row "Act 0, III (Frankfurt)" "Performance Replication" "Performance Replication"
row "Acts II, IV, V (Dublin)" "DR Replication" "DR Replication"
row "Act 0 (payments, -eu)" "Namespaces" "Namespaces"
row "Act 0 (standbys serve)" "Performance Standby" "Performance Standby"
row "Epilogue (audit)" "edition"
echo
echo "Feature names in the licence:"
sed 's/^/  - /' <<<"$features"
exit "$missing"
