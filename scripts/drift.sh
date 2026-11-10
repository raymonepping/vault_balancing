#!/usr/bin/env bash
# scripts/drift.sh [--prove] (make drift): read-only by default.
# `terraform plan -detailed-exitcode` on every Terraform root (the "seal" phase
# is one root per site) and `--check` on every Ansible phase; one table.
# TF_ONLY=1: Terraform only (make lab, after idempotency).
# --prove (make drift): first prove drift is caught. Per root, change one
# declared value OUT OF BAND (the vault CLI with that root's own token, outside
# Terraform's state: the Ansible tokens are denied ACL writes on purpose), see
# the plan show it, apply to restore it, see the plan empty again. The change
# is a comment line in a policy: it never alters what a token may do.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
mkdir -p "$BUILD_DIR/logs" "$BUILD_DIR/gates"
rows=()
fails=0

prove() { # <root> <token> <policy path> <where: seal-<site>|primary>
  local root=$1 token=$2 path=$3 where=$4 rc log="$BUILD_DIR/logs/drift-prove-$1.log" body
  if [ "$where" = primary ]; then vault_primary; else vault_node "$where"; fi
  vault_token "$token"
  body=$(vault read -format=json "$path" | jq -r '.data.policy // .data.rules')
  printf '%s\n# out-of-band change by make drift\n' "$body" | vault write "$path" policy=- >/dev/null
  unset VAULT_TOKEN
  rc=0
  ./scripts/tf.sh "$root" plan -no-color >"$log" 2>&1 </dev/null || rc=$?
  [ "$rc" = 2 ] || { rows+=("$root|prove|MISSED|plan exit $rc after the out-of-band change"); fails=$((fails + 1)); return; }
  ./scripts/tf.sh "$root" apply -no-color >>"$log" 2>&1 </dev/null || { rows+=("$root|prove|ERROR|apply failed, see ${log#"$VBAL_ROOT"/}"); fails=$((fails + 1)); return; }
  rc=0
  ./scripts/tf.sh "$root" plan -no-color >>"$log" 2>&1 </dev/null || rc=$?
  if [ "$rc" = 0 ]; then rows+=("$root|prove|caught|plan saw $path, apply restored it, plan empty")
  else
    rows+=("$root|prove|ERROR|plan exit $rc after the restore")
    fails=$((fails + 1))
  fi
}
if [ "${1:-}" = --prove ]; then
  for s in $VBAL_SITES; do prove "seal-$s" "tf-seal-$s" sys/policies/acl/autounseal "seal-$s"; done
  [ -f terraform/platform/versions.tf ] && prove platform tf-platform payments/sys/policies/acl/vbal-app-ticker primary
fi

tf_roots() { # the phase name -> its roots
  if [ "$1" = seal ]; then for s in $VBAL_SITES; do echo "seal-$s"; done; else echo "$1"; fi
}
while read -r tool name; do
  log="$BUILD_DIR/logs/drift-$name.log"
  if [ "$tool" = tf ]; then
    for r in $(tf_roots "$name"); do
      log="$BUILD_DIR/logs/drift-$r.log"
      rc=0
      ./scripts/tf.sh "$r" plan -no-color >"$log" 2>&1 </dev/null || rc=$?
      case $rc in
      0) rows+=("$r|terraform|clean|plan empty") ;;
      2)
        rows+=("$r|terraform|DRIFT|$(grep -E '^Plan:' "$log" | head -1)")
        fails=$((fails + 1))
        ;;
      *)
        rows+=("$r|terraform|ERROR|see ${log#"$VBAL_ROOT"/}")
        fails=$((fails + 1))
        ;;
      esac
    done
  elif [ "$tool" = ansible ] && [ "${TF_ONLY:-0}" != 1 ]; then
    if ./scripts/ansible.sh "$name" --check >"$log" 2>&1; then
      changed=$(jq -r '.changed_total' "$BUILD_DIR/ansible-stats/$name.check.json")
      if [ "$changed" = 0 ]; then rows+=("$name|ansible|clean|check mode changed=0")
      else
        rows+=("$name|ansible|DRIFT|check mode would change $changed")
        fails=$((fails + 1))
      fi
    else
      rows+=("$name|ansible|ERROR|see ${log#"$VBAL_ROOT"/}")
      fails=$((fails + 1))
    fi
  fi
done < <(phases)
printf '\n%-16s %-10s %-7s %s\n' LAYER TOOL RESULT DETAIL
for row in "${rows[@]}"; do
  IFS='|' read -r l t r d <<<"$row"
  printf '%-16s %-10s %-7s %s\n' "$l" "$t" "$r" "$d"
done
jq -n --arg result "$([ "$fails" -eq 0 ] && echo pass || echo fail)" --arg scope "$([ "${TF_ONLY:-0}" = 1 ] && echo terraform || echo all)" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{gate: "drift", scope: $scope, result: $result, at: $at}' >"$BUILD_DIR/gates/drift.json"
[ "$fails" -eq 0 ] || die "$fails layer(s) drifted."
info "No drift"
