#!/usr/bin/env bash
# scripts/idempotency.sh (make idempotency): run every Ansible phase again;
# each must report changed=0 (exceptions only from idempotency-allow.txt,
# each with a reason). Counts come from the vbal_stats callback.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
mkdir -p "$BUILD_DIR/logs" "$BUILD_DIR/gates"
allowed() { grep -Eq "^$1[[:space:]]" scripts/idempotency-allow.txt; }
fails=0
rows=()
while read -r phase; do
  printf '  idempotency: %s\n' "$phase" >&2
  if ! ./scripts/ansible.sh "$phase" >"$BUILD_DIR/logs/idempotency-$phase.log" 2>&1; then
    rows+=("$phase|FAILED|see .build/logs/idempotency-$phase.log")
    fails=$((fails + 1))
    continue
  fi
  changed=$(jq -r '.changed_total' "$BUILD_DIR/ansible-stats/$phase.json")
  if [ "$changed" = 0 ]; then rows+=("$phase|changed=0|")
  elif allowed "$phase"; then rows+=("$phase|changed=$changed (allowed)|")
  else
    rows+=("$phase|changed=$changed|see .build/logs/idempotency-$phase.log")
    fails=$((fails + 1))
  fi
done < <(phases ansible)
printf '\n%-14s %-22s %s\n' PHASE RESULT DETAIL
for row in "${rows[@]}"; do
  IFS='|' read -r p r d <<<"$row"
  printf '%-14s %-22s %s\n' "$p" "$r" "$d"
done
jq -n --arg result "$([ "$fails" -eq 0 ] && echo pass || echo fail)" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{gate: "idempotency", result: $result, at: $at}' >"$BUILD_DIR/gates/idempotency.json"
[ "$fails" -eq 0 ] || die "$fails phase(s) are not idempotent."
info "Idempotency: every Ansible phase changed=0"
