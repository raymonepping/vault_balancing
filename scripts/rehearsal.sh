#!/usr/bin/env bash
# scripts/rehearsal.sh (make rehearsal): the day before. Every step counted:
#   1. make lab again (idempotent), every plan empty, boundary, drift proof
#   2. a whole drill (DRILL_AUTO=1) and its report: RTO under a bound, RPO
#   3. after the failback: plans empty, every Ansible phase changed=0, ticker
#   4. make down && make up: roles, streaming, DR token (validate)
#   5. make test-ui
#   6. the secret scan, drill journals and reports included
# RTO bound: 30 s (ten measured runs: 8.8 to 12.3 s; docs/capabilities.md).
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
mkdir -p "$BUILD_DIR/logs"
RTO_BOUND=${RTO_BOUND:-30}
pass=0
fail=0
t0=$(date +%s)
check() { # <label> <command...>
  local label=$1 log
  shift
  log="$BUILD_DIR/logs/rehearsal-$(tr ' /' '__' <<<"$label").log"
  if "$@" >"$log" 2>&1; then
    printf '  \033[32mPASS\033[0m %s\n' "$label"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m %s (%s)\n' "$label" "${log#"$VBAL_ROOT"/}"
    fail=$((fail + 1))
  fi
}
rto_ok() { jq -e --argjson b "$RTO_BOUND" '.rto.total_s != null and .rto.total_s <= $b' .build/drill/latest/report.json; }
rpo_known() { jq -e '.rpo.lost_writes != null' .build/drill/latest/report.json; }
failback_zero() { jq -e '.failback.lost_writes == 0' .build/drill/latest/report.json; }

echo "1. the lab"
check "make lab (idempotent, gates green)" make --no-print-directory lab
check "every Terraform plan empty" make --no-print-directory tf-plan-all
check "boundary" ./scripts/boundary-check.sh
check "drift is caught and restored" ./scripts/drift.sh --prove
echo "2. the drill"
check "a whole drill and its report" env DRILL_AUTO=1 ./scripts/drill.sh
check "RTO within ${RTO_BOUND}s" rto_ok
check "RPO measured" rpo_known
check "planned failback lost nothing" failback_zero
echo "3. after the failback"
check "every Terraform plan empty" make --no-print-directory tf-plan-all
check "every Ansible phase changed=0" ./scripts/idempotency.sh
check "Act 0 again (validate)" ./scripts/ansible.sh validate
echo "4. down and up"
check "make down" make --no-print-directory down
check "make up" ./scripts/up.sh
check "Act 0 after up (validate)" ./scripts/ansible.sh validate
check "verify" ./scripts/verify.sh
echo "5. the console"
check "make test-ui" make --no-print-directory test-ui
echo "6. secrets"
check "secret scan (state, .build with drill journals, container logs)" ./scripts/secret-scan.sh
echo
printf 'rehearsal: PASS %s / FAIL %s in %ss (RTO this run: %ss)\n' "$pass" "$fail" "$(($(date +%s) - t0))" "$(jq -r .rto.total_s .build/drill/latest/report.json 2>/dev/null || echo -)"
[ "$fail" -eq 0 ]
