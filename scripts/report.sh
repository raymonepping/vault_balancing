#!/usr/bin/env bash
# scripts/report.sh [--keep-open] (make report): the epilogue of the open (or
# latest) drill. Copies the ticker's journal for the drill's window into the
# drill dir, collects Vault's own audit record of every replication
# promote/demote/update-primary on every running node, runs report.js
# (report.json, report.md) and closes the drill.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
keep=false
[ "${1:-}" = --keep-open ] && keep=true
id=$(./scripts/journal.sh id)
[ -n "$id" ] || id=$(readlink .build/drill/latest 2>/dev/null || true)
[ -n "$id" ] && [ -s ".build/drill/$id/journal.jsonl" ] || die "report: no drill to report (make drill, or make site-down SITE=...)"
dir=".build/drill/$id"
from=$(head -1 "$dir/journal.jsonl" | jq -r .ts)
to=$(tail -1 "$dir/journal.jsonl" | jq -r .ts)

# The ticker's own lines of the drill window (one file per drill, D10).
podman exec vbal-ticker sh -c 'cat /data/previous.jsonl /data/current.jsonl 2>/dev/null' |
  jq -c --arg f "$from" --arg t "$to" 'select(.sent_at >= $f and .sent_at <= $t)' >"$dir/ticker.jsonl" 2>/dev/null || true

# Vault's audit record: the replication calls of this window, per node (paths
# and times only; the audit log HMACs every token).
audit="[]"
for s in $VBAL_SITES; do
  for n in $(site_nodes "$s"); do
    c=$(vault_container "$n")
    [ "$(vbal_container_state "$c")" = running ] || continue
    rows=$(podman exec "$c" sh -c "grep -h 'sys/replication/' /vault/audit/audit.log 2>/dev/null | grep '\"type\":\"response\"' | tail -n 400" |
      jq -c --arg n "$n" --arg f "$from" --arg t "$to" \
        'select(.time >= $f and .time <= $t and (.request.path | test("promote|demote|update-primary|secondary-token|secondary/enable")))
         | {node: $n, path: .request.path, time: .time}' 2>/dev/null | jq -s . || echo '[]')
    audit=$(jq -c --argjson a "$audit" --argjson b "${rows:-[]}" -n '$a + $b')
  done
done
jq '. | sort_by(.time)' <<<"$audit" >"$dir/audit.json"

VBAL_TICK_MS=$(vbal_conf VBAL_TICK_MS) node scripts/report.js "$dir"
echo "report: $dir/report.md ($(wc -l <"$dir/ticker.jsonl" | tr -d ' ') ticker lines, $(jq length "$dir/audit.json") audit records)"
[ "$keep" = true ] || ./scripts/journal.sh close
