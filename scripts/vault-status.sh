#!/usr/bin/env bash
# scripts/vault-status.sh: one row per Vault (three seal Vaults, nine nodes),
# with Vault's own answers: sys/health code, HA role, replication modes.
# Read-only, no token (both endpoints are unauthenticated).
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

health_name() {
  case "$1" in
  200) echo active ;; 429) echo standby ;; 472) echo dr-secondary ;; 473) echo perf-standby ;;
  501) echo uninit ;; 503) echo sealed ;; 000) echo unreachable ;; *) echo "http-$1" ;;
  esac
}
printf '%-5s %-12s %-18s %-5s %-6s %-8s %-4s %-13s %-26s %s\n' SITE HOST CONTAINER INIT SEALED SEAL CODE HA REPLICATION VERSION
for site in $VBAL_SITES; do
  for host in "seal-$site" $(site_nodes "$site"); do
    c=$(vault_container "$host")
    cstate=$(vbal_container_state "$c")
    if [ "$cstate" != running ]; then
      printf '%-5s %-12s %-18s %s\n' "$site" "$host" "$c" "$cstate"
      continue
    fi
    vault_node "$host"
    if ! s=$(vault_json 2>/dev/null); then
      printf '%-5s %-12s %-18s %s\n' "$site" "$host" "$c" "unreachable"
      continue
    fi
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/sys/health" || true)
    repl=-
    if [[ "$host" == vault-* ]] && jq -e '.initialized and (.sealed | not)' <<<"$s" >/dev/null; then
      repl=$(curl -sf --max-time 5 --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/sys/replication/status" |
        jq -r '"perf:\(.data.performance.mode // "-") dr:\(.data.dr.mode // "-")"' 2>/dev/null || echo -)
    fi
    printf '%-5s %-12s %-18s %-5s %-6s %-8s %-4s %-13s %-26s %s\n' "$site" "$host" "$c" \
      "$(jq -r .initialized <<<"$s")" "$(jq -r .sealed <<<"$s")" "$(jq -r .type <<<"$s")" \
      "$code" "$(health_name "$code")" "$repl" "$(jq -r .version <<<"$s")"
  done
done
