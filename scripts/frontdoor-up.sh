#!/usr/bin/env bash
# scripts/frontdoor-up.sh: phase 10 (make frontdoor-up). Render haproxy.cfg
# (Ansible, role frontdoor: topology + fence list), start HAProxy, wait until
# its stats answer. A re-run re-renders and reloads only on a change.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
./scripts/network.sh
./scripts/ansible.sh frontdoor >"$BUILD_DIR/logs/frontdoor.log" 2>&1 || {
  tail -20 "$BUILD_DIR/logs/frontdoor.log" >&2
  die "frontdoor-up: rendering the config failed (.build/logs/frontdoor.log)"
}
./scripts/compose.sh frontdoor up -d >/dev/null
for _ in $(seq 1 30); do
  if curl -sf --max-time 2 "http://127.0.0.1:$(vbal_conf VBAL_PORT_STATS)/stats;csv" >/dev/null; then
    echo "frontdoor-up: HAProxy answers (writes https://127.0.0.1:$(vbal_conf VBAL_PORT_FRONTDOOR), stats http://127.0.0.1:$(vbal_conf VBAL_PORT_STATS)/stats)"
    exit 0
  fi
  sleep 1
done
die "frontdoor-up: HAProxy stats do not answer (make frontdoor-logs)"
