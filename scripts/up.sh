#!/usr/bin/env bash
# scripts/up.sh (make up): the daily start after the Mac slept or rebooted.
# Clock, every site (its seal Vault started AND unsealed before its nodes,
# gotcha 20; quorum per site), the declared structure Vault forgets on a
# restart (tf platform: the paths filters for ids not issued yet), the front door (fence list honoured), the app,
# and a fresh DR operations token when less than 4h is left (D9: batch tokens
# cannot be renewed). A half-finished drill is state, not something to paper
# over: a site the open drill killed is not started, and the targets that
# finish the job are printed. Volumes are never touched.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
step() { printf '\033[1m%-11s\033[0m %s\n' "$1" "$2"; }
mkdir -p "$BUILD_DIR/logs"

step clock-sync "$(./scripts/clock-sync.sh 2>&1 | tail -1)"
skip=""
open=$(./scripts/journal.sh id)
if [ -n "$open" ] && [ -s "$BUILD_DIR/drill/$open/state.json" ]; then
  down=$(jq -r '.down.site // empty' "$BUILD_DIR/drill/$open/state.json")
  role=$(jq -r '.down.role_before // empty' "$BUILD_DIR/drill/$open/state.json")
  if [ -n "$down" ]; then
    skip=$down
    step drill "open drill $open: $down is down (it was $role). Not starting it. Finish the drill: $([ "$role" = primary ] && echo "make fence SITE=$down && make site-up SITE=$down && make demote SITE=$down TO=<primary> && make unfence SITE=$down && make failback" || echo "make site-up SITE=$down"), then make report"
  fi
fi
sites=""
for s in $VBAL_SITES; do [ "$s" = "$skip" ] || sites="$sites $s"; done
# shellcheck disable=SC2086  # one word per site
./scripts/sites-up.sh $sites >"$BUILD_DIR/logs/up-sites.log" 2>&1 || {
  tail -15 "$BUILD_DIR/logs/up-sites.log" >&2
  die "up: the sites did not come up (make vault-status, make <site>-logs)"
}
step sites "$(grep -c 'is the leader' "$BUILD_DIR/logs/up-sites.log") site(s) with a leader:$sites"
# Vault keeps a paths filter only for a secondary id it knows: the filters
# declared ahead for the ids a drill may use are gone after a restart. Terraform
# puts them back (gotcha 28).
if [ -z "$skip" ]; then
  ./scripts/tf.sh platform apply -no-color >"$BUILD_DIR/logs/up-platform.log" 2>&1 || die "up: tf platform failed (.build/logs/up-platform.log)"
  step platform "$(grep -E '^Apply complete' "$BUILD_DIR/logs/up-platform.log" | sed 's/\x1b\[[0-9;]*m//g')"
fi
./scripts/frontdoor-up.sh >"$BUILD_DIR/logs/up-frontdoor.log" 2>&1 || die "up: the front door did not start (.build/logs/up-frontdoor.log)"
step frontdoor "HAProxy answers; fenced: $(cat "$BUILD_DIR/frontdoor/fenced.json" 2>/dev/null || echo '[]')"
./scripts/identity-up.sh >"$BUILD_DIR/logs/up-identity.log" 2>&1 || die "up: identity did not come up (.build/logs/up-identity.log)"
step identity "OpenLDAP and Keycloak (realm balancing)"
./scripts/app-up.sh ticker api web >"$BUILD_DIR/logs/up-app.log" 2>&1 || {
  tail -5 "$BUILD_DIR/logs/up-app.log" >&2
  die "up: the app did not come up (make app-logs)"
}
step app "ticker, api and web healthy"
step runner "$(./scripts/runner.sh up)"
step audit "$(./scripts/audit-rotate.sh | tail -1 | sed 's/^audit-rotate: //')"
./scripts/ansible.sh dr-token >"$BUILD_DIR/logs/up-dr-token.log" 2>&1 || die "up: no DR operations token (.build/logs/up-dr-token.log)"
step dr-token "$(grep -o 'DR operations token: [^"]*' "$BUILD_DIR/logs/up-dr-token.log" | tail -1)"
echo "up: done. make verify to check, make doctor if something looks wrong, make show-ready before a talk."
