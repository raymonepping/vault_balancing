#!/usr/bin/env bash
# scripts/tf.sh <root> <init|plan|apply|output|state-list|destroy> [terraform args...]
#
# The only supported way to run Terraform here. Roots:
#   seal-<site>  terraform/seal on that site's seal Vault, token tf-seal-<site>
#   platform     terraform/platform on whichever site is primary NOW (D8:
#                Vault's own sys/replication/status decides), token tf-platform
# Each root has its own state and data dir in .secrets/terraform/<root>/ (0600
# after every run) and writes the non-secret evidence .build/terraform/<root>.json.
# Never echoes a token.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

usage="Usage: tf.sh <seal-<site>|platform|probe> <init|plan|apply|output|state-list|destroy> [args]"
root=${1:?$usage}
action=${2:?$usage}
shift 2

case "$root" in
seal-*)
  site=${root#seal-}
  site_exists "$site"
  dir="$VBAL_ROOT/terraform/seal" token="tf-seal-$site"
  vault_node "seal-$site"
  export TF_VAR_site="$site"
  ;;
platform)
  dir="$VBAL_ROOT/terraform/platform" token=tf-platform
  vault_primary || die "tf platform: no primary to plan against."
  info "tf platform: planning against $VBAL_PRIMARY (the site Vault reports as primary)"
  # The paths filter is keyed by Frankfurt's activation id: the current one and
  # the next two a drill may allocate (empty until replicate).
  TF_VAR_fra_secondary_ids=$(jq -c '(.fra.n // 0) as $n | if $n == 0 then [] else [range($n; $n + 3) | "fra-\(.)"] end' \
    "$VBAL_STATE/replication-ids.json" 2>/dev/null || echo '[]')
  export TF_VAR_fra_secondary_ids
  ;;
probe)
  dir="$VBAL_ROOT/terraform/probe" token=""
  VAULT_ADDR="https://127.0.0.1:$(vbal_conf VBAL_PORT_PROBE_A)"
  # Only make probe calls this, with the scratch root token in its private temp dir.
  [ -s "${VBAL_PROBE_ROOT_FILE:-}" ] || die "tf probe: run make probe (it creates the scratch cluster)"
  VAULT_TOKEN=$(cat "$VBAL_PROBE_ROOT_FILE")
  export VAULT_TOKEN
  ;;
*) die "tf: unknown root '$root' ($usage)" ;;
esac
[ -f "$dir/versions.tf" ] || die "tf: root '$root' is not built yet ($dir)"
if [ -n "$token" ] && [ "$action" != output ] && [ "$action" != state-list ]; then vault_token "$token"; fi
export VAULT_ADDR VAULT_CACERT
export TF_VAR_vault_addr="$VAULT_ADDR" TF_VAR_vault_cacert="$VAULT_CACERT"

state_dir="$VBAL_ROOT/.secrets/terraform/$root"
mkdir -p "$state_dir" "$BUILD_DIR/terraform"
chmod 700 "$VBAL_ROOT/.secrets/terraform" "$state_dir"
export TF_DATA_DIR="$state_dir/.terraform"
state="$state_dir/terraform.tfstate"
lock_down() { find "$state_dir" -maxdepth 1 -name '*.tfstate*' -exec chmod 600 {} + 2>/dev/null || true; }
trap lock_down EXIT

cd "$dir"
terraform init -input=false -backend-config="path=$state" >/dev/null

evidence() { # field value
  local f="$BUILD_DIR/terraform/$root.json" cur='{}' count
  [ -s "$f" ] && cur=$(cat "$f")
  count=$(terraform state list 2>/dev/null | grep -cv '^data\.' || true)
  jq --arg k "$1" --argjson v "$2" --argjson c "${count:-0}" --arg root "$root" --arg addr "$VAULT_ADDR" \
    '.root = $root | .vault_addr = $addr | .[$k] = $v | .resources = $c' <<<"$cur" >"$f.tmp" && mv "$f.tmp" "$f"
}
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

rc=0
case "$action" in
init) ;;
plan)
  terraform plan -input=false -detailed-exitcode -lock-timeout=60s "$@" || rc=$?
  [ "$rc" -le 2 ] && evidence last_plan "$(jq -n --arg at "$(now)" --argjson rc "$rc" '{at: $at, exit: $rc, changes: ($rc == 2)}')"
  ;;
apply)
  terraform apply -input=false -auto-approve -lock-timeout=60s "$@" || rc=$?
  [ "$rc" -eq 0 ] && evidence last_apply "$(jq -n --arg at "$(now)" '{at: $at}')"
  ;;
destroy) terraform destroy -input=false -auto-approve "$@" || rc=$? ;;
output) terraform output "$@" || rc=$? ;;
state-list) terraform state list "$@" || rc=$? ;;
*) die "tf: unknown action '$action'" ;;
esac
exit "$rc"
