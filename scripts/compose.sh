#!/usr/bin/env bash
# scripts/compose.sh: thin Podman Compose wrapper for the vault_balancing stacks.
# Usage: compose.sh <stack> <compose arguments...>
#
# Stacks: one per site (ams fra dub), plus frontdoor, app and probe. The three
# sites share ONE file, compose/site/compose.yaml, parametrised by SITE and
# its ports (three near-copies would have to change together). Each stack is
# its own compose project vbal-<stack> on the shared network vbal-internal.
# config/defaults.conf is loaded first, .env second, so .env wins.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

STACKS="$VBAL_SITES frontdoor identity app probe"
[ "$#" -ge 2 ] || {
  echo "Usage: $0 <stack> <compose arguments...>" >&2
  echo "Stacks: $STACKS" >&2
  exit 64
}
stack=$1
shift
[[ " $STACKS " == *" $stack "* ]] || {
  echo "Unknown stack: $stack (known: $STACKS)" >&2
  exit 64
}

dir=$stack
if [[ " $VBAL_SITES " == *" $stack "* ]]; then
  dir=site
  SITE=$stack
  SITE_PORT_SEAL=$(vault_port_of "seal-$stack")
  SITE_PORT_1=$(vault_port_of "vault-$stack-1")
  SITE_PORT_2=$(vault_port_of "vault-$stack-2")
  SITE_PORT_3=$(vault_port_of "vault-$stack-3")
  export SITE SITE_PORT_SEAL SITE_PORT_1 SITE_PORT_2 SITE_PORT_3
fi
compose_file="$VBAL_ROOT/compose/$dir/compose.yaml"
[ -f "$compose_file" ] || {
  echo "Stack '$stack' is not implemented yet: compose/$dir/compose.yaml is missing." >&2
  exit 66
}
command -v podman >/dev/null 2>&1 || {
  echo "Podman is required but was not found in PATH." >&2
  exit 69
}
[ -f "$VBAL_ROOT/.env" ] || {
  echo "Missing .env: run make env-init" >&2
  exit 66
}
export VBAL_ROOT

# A Docker-era COMPOSE_FILE list in the user's shell must not leak in.
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME

run_compose() {
  podman compose \
    --project-name "vbal-$stack" \
    --project-directory "$VBAL_ROOT/compose/$dir" \
    --file "$compose_file" \
    --env-file "$VBAL_ROOT/config/defaults.conf" \
    --env-file "$VBAL_ROOT/.env" \
    "$@"
}

if [ "${1:-}" != "up" ]; then
  run_compose "$@"
  exit $?
fi

log=$(mktemp)
trap 'rm -f "$log"' EXIT
status=0
run_compose "$@" >"$log" 2>&1 || status=$?
cat "$log"
# One retry on the known dependent-container race.
if [ "$status" -ne 0 ] && grep -qE 'dependent container|already in use' "$log"; then
  echo "[compose.sh] '$stack up' hit the known dependent-container race: retrying once" >&2
  status=0
  run_compose "$@" >"$log" 2>&1 || status=$?
  cat "$log"
fi
exit "$status"
