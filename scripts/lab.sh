#!/usr/bin/env bash
# scripts/lab.sh (make lab): golden_ticket's phased, fail-closed workflow.
# Every phase of scripts/phases.txt in order (Terraform builds the house,
# Ansible decorates it, Make starts what runs), then the gates: idempotency,
# drift (Terraform), secret scan, boundary. Only then .build/convergence.json.
# On failure the exact resume command is printed.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"

started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
t_start=$(date +%s)
banner() { printf '\n\033[1;7m %s \033[0m %s\n\n' "$1" "$2" >&2; }
fail() {
  printf '\n\033[31m%s failed.\033[0m Fix the reported error, then resume with:\n  %s && make lab\n' "$1" "$2" >&2
  exit 1
}

mapfile -t PHASES < <(phases)
total=$((${#PHASES[@]} + 4))
make -s check >/dev/null || fail "make check" "make check"
mkdir -p "$BUILD_DIR/gates"

timings="{}"
n=0
for entry in "${PHASES[@]}"; do
  read -r tool name <<<"$entry"
  n=$((n + 1))
  banner "$n/$total" "$tool $name"
  t0=$(date +%s)
  case "$tool" in
  make) make --no-print-directory "$name" || fail "$tool $name" "make $name" ;;
  tf)
    if [ "$name" = seal ]; then # one root per site
      for s in $VBAL_SITES; do ./scripts/tf.sh "seal-$s" apply -no-color || fail "tf seal-$s" "make tf-seal-all"; done
    else ./scripts/tf.sh "$name" apply -no-color || fail "$tool $name" "make tf-$name"; fi
    ;;
  ansible) ./scripts/ansible.sh "$name" || fail "$tool $name" "make $name" ;;
  *) fail "unknown tool '$tool' in phases.txt" "edit scripts/phases.txt" ;;
  esac
  timings=$(jq --arg p "$name" --argjson s "$(($(date +%s) - t0))" '.[$p] = $s' <<<"$timings")
done

n=$((n + 1)); banner "$n/$total" "gate: idempotency (every Ansible phase again, changed=0)"
./scripts/idempotency.sh || fail "The idempotency gate" "make idempotency"
n=$((n + 1)); banner "$n/$total" "gate: drift (every Terraform plan empty)"
TF_ONLY=1 ./scripts/drift.sh || fail "The drift gate" "make drift"
n=$((n + 1)); banner "$n/$total" "gate: secret scan"
./scripts/secret-scan.sh || fail "The secret scan" "make secret-scan"
n=$((n + 1)); banner "$n/$total" "gate: boundary"
./scripts/boundary-check.sh || fail "The boundary gate" "make boundary"

vault_primary
primary=$VBAL_PRIMARY
jq -n \
  --arg primary "$primary" \
  --arg started "$started_at" \
  --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson seconds "$(($(date +%s) - t_start))" \
  --arg digest "$(./scripts/automation-digest.sh)" \
  --arg version "$(vault_json | jq -r .version)" \
  --argjson phases "$(printf '%s\n' "${PHASES[@]}" | jq -R 'split(" ") | {tool: .[0], phase: .[1]}' | jq -s .)" \
  --argjson timings "$timings" \
  '{result: "success", phases: $phases, phase_seconds: $timings, seconds: $seconds,
    started_at: $started, finished_at: $finished, automation_digest: $digest,
    primary: $primary, vault_version: $version}' \
  >"$BUILD_DIR/convergence.json.tmp"
mv "$BUILD_DIR/convergence.json.tmp" "$BUILD_DIR/convergence.json"
./scripts/layers.sh
banner "done" "vault_balancing converged in $(($(date +%s) - t_start))s, digest $(jq -r '.automation_digest[0:12]' "$BUILD_DIR/convergence.json"), evidence in .build/"
