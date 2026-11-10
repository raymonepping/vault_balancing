#!/usr/bin/env bash
# scripts/drill-runs.sh [N] (make drill-runs N=10): open question 6. N whole
# drills in a row (DRILL_AUTO=1), then min, median and max of RTO and RPO
# from their reports, appended to docs/capabilities.md under "Measured".
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
n=${1:-10}
ids=()
for i in $(seq 1 "$n"); do
  info "drill-runs: run $i of $n"
  DRILL_AUTO=1 ./scripts/drill.sh >".build/logs/drill-run-$i.log" 2>&1 || die "drill-runs: run $i failed (.build/logs/drill-run-$i.log)"
  ids+=("$(readlink .build/drill/latest)")
done
reports=$(for id in "${ids[@]}"; do cat ".build/drill/$id/report.json"; done | jq -s .)
others=$(podman ps --format '{{.Names}}' | grep -vc '^vbal-' || true)
summary=$(jq -r --arg others "$others" '
  def stats(f): (map(f) | sort) as $v | {min: $v[0], median: $v[(($v | length) / 2 | floor)], max: $v[-1]};
  (stats(.rto.total_s)) as $rto | (stats(.rto.detection_s)) as $det | (stats(.rto.promotion_s)) as $pro |
  (stats(.rpo.lost_writes)) as $lw | (stats(.rpo.lost_seconds)) as $ls | (map(.failback.lost_writes) | add) as $fb |
  "| RTO total (s) | \($rto.min) | \($rto.median) | \($rto.max) |",
  "| detection (s) | \($det.min) | \($det.median) | \($det.max) |",
  "| promotion and first write (s) | \($pro.min) | \($pro.median) | \($pro.max) |",
  "| RPO lost writes | \($lw.min) | \($lw.median) | \($lw.max) |",
  "| RPO lost seconds | \($ls.min) | \($ls.median) | \($ls.max) |",
  "",
  "\(length) runs; writes lost in the planned failbacks, all runs together:",
  "\($fb). Other containers running: \($others)."' <<<"$reports")
{
  echo
  echo "## Measured: $n drills ($(date -u +%Y-%m-%d), make drill-runs)"
  echo
  echo "Each run: Amsterdam killed (podman kill), Dublin promoted with the DR"
  echo "operations token, Frankfurt followed, Amsterdam fenced, demoted and"
  echo "re-attached, planned failback. One Mac, not three regions."
  echo
  echo "| Measure | Min | Median | Max |"
  echo "| --- | --- | --- | --- |"
  echo "$summary"
} >>docs/capabilities.md
echo "$summary"
