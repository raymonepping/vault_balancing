#!/usr/bin/env bash
# scripts/ticker.sh status|tail|reset (make ticker-status): the ticker's own
# view. status: /metrics; tail: the journal as it grows; reset: truncate the
# journal (CONFIRM=yes), never the Vault data and never the seq counter.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
metrics() { podman exec vbal-ticker node -e "fetch('http://127.0.0.1:9100/metrics').then(r=>r.text()).then(t=>process.stdout.write(t))"; }
case "${1:-status}" in
status)
  m=$(metrics) || die "ticker: not running (make app-up)"
  jq -r '"last acknowledged seq \(.last_ack_seq) at \(.last_ack_at // "-")",
    "last 10 s: \(.acked_10s) acknowledged, \(.fail_10s) failed, p50 \(.p50_ms // "-" | tostring | .[0:6]) ms, p99 \(.p99_ms // "-" | tostring | .[0:6]) ms",
    "regional (Frankfurt): lag \(if .regional_lag == null then "unknown" else "\(.regional_lag) seq" end)\(if .regional_error then " (\(.regional_error))" else "" end)"' <<<"$m"
  ;;
tail) podman exec vbal-ticker tail -f /data/current.jsonl ;;
reset)
  [ "${CONFIRM:-}" = yes ] || {
    printf 'Truncate the ticker journal (Vault data and seq stay)? Type yes: '
    read -r a
    [ "$a" = yes ] || exit 1
  }
  podman exec vbal-ticker sh -c ': > /data/current.jsonl; rm -f /data/previous.jsonl'
  echo "ticker: journal truncated"
  ;;
*) die "Usage: ticker.sh status|tail|reset" ;;
esac
