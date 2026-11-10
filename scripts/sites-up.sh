#!/usr/bin/env bash
# scripts/sites-up.sh [site...]: phase 5 (make sites-up) and the cold start.
# scripts/sites-up.sh --followers <site>: start nodes 2..n of an activated secondary.
#
# Per site: the seal Vault up AND unsealed (gotcha 20), then the nodes, each
# unsealing itself through Transit with its own seal token (a node whose seal
# Vault is unreachable exits at start, gotcha 2). A secondary-to-be that is
# not activated yet starts node 1 only (its followers would join a Raft
# cluster that activation wipes); once Vault reports it as a secondary, all
# of its nodes start together (an existing Raft cluster must start as a
# whole, gotcha 15). On the very first run node 1 is not initialised yet:
# phase bootstrap does that, so this script stops at "answers".
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
compose() { "$VBAL_ROOT/scripts/compose.sh" "$@"; }

followers_only=false
if [ "${1:-}" = --followers ]; then
  followers_only=true
  shift
fi
sites=${*:-$VBAL_SITES}
"$VBAL_ROOT/scripts/network.sh"
restart=$(sort -u "$BUILD_DIR/seal-restart" 2>/dev/null | tr '\n' ' ' || true)

start_node() { # <node>: start it, or restart it when its seal token changed
  local node=$1 c
  c=$(vault_container "$node")
  [ -s "$VBAL_STATE/seal/$node" ] || die "sites-up: no seal token for $node: run make seal-tokens"
  if [[ " $restart " == *" $node "* ]] && [ "$(vbal_container_state "$c")" = running ]; then
    podman restart "$c" >/dev/null
    echo "sites-up: $node restarted to read its new seal token"
  else
    compose "$(site_of "$node")" up -d "vault-${node##*-}" >/dev/null 2>&1
  fi
  vault_node "$node"
  vault_wait reachable 45
}

wait_leader() { # <site> <nodes...>
  local site=$1 node
  shift
  for node in "$@"; do
    vault_node "$node"
    vault_wait unsealed 90
  done
  for _ in $(seq 1 60); do
    for node in "$@"; do
      vault_node "$node"
      if curl -sf --max-time 5 --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/sys/leader" | jq -e '.is_self' >/dev/null 2>&1; then
        echo "sites-up: $site: $# node(s) unsealed, $node is the leader"
        return 0
      fi
    done
    sleep 2
  done
  die "sites-up: $site: no leader after 120s (make vault-status, make $site-logs)"
}

for site in $sites; do
  site_exists "$site"
  read -r -a nodes <<<"$(site_nodes "$site")"
  if [ "$followers_only" = true ]; then
    for node in "${nodes[@]:1}"; do start_node "$node"; done
    wait_leader "$site" "${nodes[@]}"
    continue
  fi
  compose "$site" up -d seal >/dev/null
  "$VBAL_ROOT/scripts/vault-unseal.sh" "$site"
  vault_node "seal-$site"
  vault_wait active

  start_node "${nodes[0]}"
  primary=false
  [ "$(site_bootstrap_role "$site")" = primary ] && primary=true
  # An activated secondary (its init root token is gone: it died on
  # activation) is an existing Raft cluster: all of it starts together, one
  # node alone has no quorum and cannot even report its mode (gotcha 15,
  # found by the rehearsal's down and up).
  activated=false
  if [ "$primary" = false ] && [ -s "$VBAL_STATE/vault-$site-init.json" ] && ! jq -e 'has("root_token")' "$VBAL_STATE/vault-$site-init.json" >/dev/null; then
    activated=true
  fi
  # The bootstrap primary starts every node: its followers wait in retry_join
  # until bootstrap initialises node 1.
  if [ "$primary" = true ] || [ "$activated" = true ]; then
    for node in "${nodes[@]:1}"; do start_node "$node"; done
  fi
  vault_node "${nodes[0]}"
  if ! vault_json | jq -e '.initialized' >/dev/null; then
    echo "sites-up: $site: seal-$site active, nodes answer; not initialised yet (phase bootstrap)"
    continue
  fi
  vault_wait unsealed 90
  all=true
  if [ "$primary" = false ] && [ "$activated" = false ]; then
    # A secondary-to-be starts its followers only once Vault says it is one.
    mode=$(curl -sf --max-time 5 --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/sys/replication/status" |
      jq -r '[.data.dr.mode, .data.performance.mode] | map(select(. != null and . != "disabled")) | join(",")' 2>/dev/null || true)
    [ -n "$mode" ] || all=false
  fi
  if [ "$primary" = true ] || [ "$activated" = true ]; then
    wait_leader "$site" "${nodes[@]}"
  elif [ "$all" = true ]; then
    for node in "${nodes[@]:1}"; do start_node "$node"; done
    wait_leader "$site" "${nodes[@]}"
  else
    wait_leader "$site" "${nodes[0]}"
    echo "sites-up: $site: node 1 only until it is activated as a secondary (prompt 05)"
  fi
done
rm -f "$BUILD_DIR/seal-restart"
