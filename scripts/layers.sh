#!/usr/bin/env bash
# scripts/layers.sh (make layers): .build/layers.json, one row per phase in
# run order with its tool and evidence, plus the gates. Non-secret: counts,
# times, results. The console's Layers page reads it (prompt 07).
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
json_or_null() { if [ -s "$1" ]; then cat "$1"; else echo null; fi; }
conv=$(json_or_null "$BUILD_DIR/convergence.json")
rows="[]"
while read -r tool name; do
  secs=$(jq -r --arg n "$name" '.phase_seconds[$n] // null' <<<"$conv")
  case "$tool" in
  tf)
    if [ "$name" = seal ]; then # one root per site: sum their evidence
      ev=$(for s in $VBAL_SITES; do json_or_null "$BUILD_DIR/terraform/seal-$s.json"; done | jq -s '
        if all(. == null) then null else
          {resources: (map(.resources // 0) | add), last_apply: {at: (map(.last_apply.at // empty) | max)},
           last_plan: (map(.last_plan // empty) | last)} end')
    else ev=$(json_or_null "$BUILD_DIR/terraform/$name.json"); fi
    rows=$(jq --arg n "$name" --argjson ev "$ev" --argjson s "$secs" \
      '. + [{phase: $n, tool: "terraform", seconds: $s, resources: ($ev.resources // null),
             last_apply: ($ev.last_apply.at // null), last_plan: ($ev.last_plan // null)}]' <<<"$rows")
    ;;
  ansible)
    run=$(json_or_null "$BUILD_DIR/ansible-stats/$name.json")
    chk=$(json_or_null "$BUILD_DIR/ansible-stats/$name.check.json")
    rows=$(jq --arg n "$name" --argjson run "$run" --argjson chk "$chk" --argjson s "$secs" \
      '. + [{phase: $n, tool: "ansible", seconds: $s,
             last_run: (if $run then {at: $run.finished_at, changed: $run.changed_total, failed: $run.failed_total} else null end),
             last_check: (if $chk then {at: $chk.finished_at, changed: $chk.changed_total} else null end)}]' <<<"$rows")
    ;;
  make)
    rows=$(jq --arg n "$name" --argjson s "$secs" '. + [{phase: $n, tool: "make", seconds: $s}]' <<<"$rows")
    ;;
  esac
done < <(phases)
gates="{}"
for gate in idempotency drift secret-scan boundary validation; do
  gates=$(jq --arg g "$gate" --argjson v "$(json_or_null "$BUILD_DIR/gates/$gate.json")" '.[$g] = $v' <<<"$gates")
done
# validation.json has no time on purpose (a timestamp would break idempotency):
# the validate phase's own recap says when it last ran.
gates=$(jq --argjson s "$(json_or_null "$BUILD_DIR/ansible-stats/validate.json")" \
  'if .validation and ($s != null) then .validation.at = $s.finished_at else . end' <<<"$gates")
jq -n --argjson rows "$rows" --argjson gates "$gates" --argjson conv "$conv" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{generated_at: $at, converged: ($conv.result // null), converged_at: ($conv.finished_at // null),
    automation_digest: ($conv.automation_digest // null), phases: $rows, gates: $gates}' >"$BUILD_DIR/layers.json.tmp"
mv "$BUILD_DIR/layers.json.tmp" "$BUILD_DIR/layers.json"
info "Wrote .build/layers.json"
