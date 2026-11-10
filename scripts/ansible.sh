#!/usr/bin/env bash
# scripts/ansible.sh <playbook> [--check] [ansible-playbook args...]
# scripts/ansible.sh --version-check
#
# The only supported way to run Ansible here. Runs from the repo root with
# ansible.cfg. Ansible refuses non-blocking stdio (agent shells, some CI), so
# stdin comes from /dev/null and output goes through cat. Passes token file
# PATHS (vbal_tokens_dir), never a token, plus the non-secret lab settings
# and the parsed topology in .build/ansible-vars.json. The vbal_stats
# callback writes the play recap counts to .build/ansible-stats/<playbook>[.check].json.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
export ANSIBLE_CONFIG="$VBAL_ROOT/ansible.cfg"

if [ "${1:-}" = --version-check ]; then
  v=$(ansible-playbook --version </dev/null 2>&1 | cat | head -1)
  echo "$v"
  [[ "$v" == *"core 2.2"[1-9]* ]] || die "ansible-core 2.21 or later is required"
  exit 0
fi

playbook=${1:?Usage: ansible.sh <playbook> [--check] [args]}
shift
playbook=${playbook%.yml}
[ -f "ansible/$playbook.yml" ] || die "ansible: unknown playbook ansible/$playbook.yml"

# Every site with its seal and node addresses, from config/sites.json and the ports.
sites_json=$(for s in $VBAL_SITES; do
  nodes=$(for n in $(site_nodes "$s"); do
    jq -n --arg n "$n" --arg a "https://127.0.0.1:$(vault_port_of "$n")" --arg c "$(vault_container "$n")" \
      '{name: $n, addr: $a, container: $c}'
  done | jq -s .)
  jq -n --arg s "$s" --arg role "$(site_bootstrap_role "$s")" \
    --arg name "$(jq -r --arg s "$s" '.sites[] | select(.id == $s) | .name' config/sites.json)" \
    --arg seal "https://127.0.0.1:$(vault_port_of "seal-$s")" --arg sealc "$(vault_container "seal-$s")" \
    --argjson nodes "$nodes" \
    '{id: $s, name: $name, bootstrap_role: $role, seal_addr: $seal, seal_container: $sealc, nodes: $nodes}'
done | jq -s .)

mkdir -p "$BUILD_DIR/ansible-stats"
jq -n \
  --arg root "$VBAL_ROOT" \
  --arg tokens "$VBAL_STATE/tokens" \
  --arg state "$VBAL_STATE" \
  --arg ca "$VAULT_CACERT" \
  --arg build "$BUILD_DIR" \
  --argjson sites "$sites_json" \
  --arg frontdoor "https://127.0.0.1:$(vbal_conf VBAL_PORT_FRONTDOOR)" \
  --arg stats "http://127.0.0.1:$(vbal_conf VBAL_PORT_STATS)" \
  --argjson dr_ttl "$(vbal_conf VBAL_DR_TOKEN_TTL)" \
  '{vbal_root: $root, vbal_tokens_dir: $tokens, vbal_state_dir: $state, vbal_ca: $ca,
    vbal_build_dir: $build, vbal_sites: $sites, vbal_frontdoor_addr: $frontdoor, vbal_stats_addr: $stats,
    vbal_dr_token_ttl: $dr_ttl}' >"$BUILD_DIR/ansible-vars.json"

# A user-run make root-regen leaves a root token file; bootstrap phases may
# use it (never revoke it: make root-revoke does) to re-apply a policy change.
if [ -n "${VBAL_ROOT_FILE:-}" ]; then
  [ -s "$VBAL_ROOT_FILE" ] || die "VBAL_ROOT_FILE=$VBAL_ROOT_FILE is not a file"
  jq --arg f "$(cd "$(dirname "$VBAL_ROOT_FILE")" && pwd)/$(basename "$VBAL_ROOT_FILE")" '. + {vbal_root_file: $f}' \
    "$BUILD_DIR/ansible-vars.json" >"$BUILD_DIR/ansible-vars.json.tmp" && mv "$BUILD_DIR/ansible-vars.json.tmp" "$BUILD_DIR/ansible-vars.json"
fi

export VBAL_PHASE="$playbook" VBAL_STATS_DIR="$BUILD_DIR/ansible-stats"
set -o pipefail
ansible-playbook "ansible/$playbook.yml" -e "@$BUILD_DIR/ansible-vars.json" "$@" </dev/null 2>&1 | cat
