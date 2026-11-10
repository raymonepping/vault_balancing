#!/usr/bin/env bash
# scripts/frontdoor-status.sh (make frontdoor-status): each backend server's
# state and its last health check, from HAProxy's stats CSV. Read-only.
# --json: the same as one JSON array (the drill playbooks wait on it).
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
csv=$(curl -sf --max-time 3 "http://127.0.0.1:$(vbal_conf VBAL_PORT_STATS)/stats;csv") || die "frontdoor-status: HAProxy stats do not answer (make frontdoor-up)"
if [ "${1:-}" = --json ]; then # for the drill playbooks: [{backend, server, status, check}]
  awk -F, 'NR > 1 && $1 ~ /^(primary|regional)$/ && $2 != "BACKEND" {print $1 "\t" $2 "\t" $18 "\t" $38}' <<<"$csv" |
    jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {backend: .[0], server: .[1], status: .[2], check: .[3]})'
  exit 0
fi
printf '%-9s %-12s %-6s %-14s %s\n' BACKEND SERVER STATE LAST-CHECK SINCE
# Columns: pxname svname ... status(17) ... lastchg(23) ... check_status(36) check_code(37)
awk -F, 'NR > 1 && $1 ~ /^(primary|regional)$/ && $2 != "BACKEND" {
  printf "%-9s %-12s %-6s %-14s %ss\n", $1, $2, $18, $37 ($38 != "" ? " " $38 : ""), $24
}' <<<"$csv"
