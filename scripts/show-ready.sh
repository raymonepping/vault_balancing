#!/usr/bin/env bash
# scripts/show-ready.sh (make show-ready): before the talk. clock-sync, up
# (with a fresh DR token when under 4h), Act 0 validated (streaming, front
# door, ticker), verify, the console. One green line, or the first failing
# step with its fix.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
t0=$(date +%s)
mkdir -p "$BUILD_DIR/logs"
run() { # <label> <fix> <command...>
  local label=$1 fix=$2
  shift 2
  if ! "$@" >"$BUILD_DIR/logs/show-ready.log" 2>&1; then
    grep -E '✗|FAIL|failed|fatal|msg' "$BUILD_DIR/logs/show-ready.log" | head -5 >&2 || tail -5 "$BUILD_DIR/logs/show-ready.log" >&2
    die "show-ready: $label failed. Fix: $fix"
  fi
}
[ -z "$(./scripts/journal.sh id)" ] || die "show-ready: a drill is open ($(./scripts/journal.sh id)). Finish it (make failback, make report) first."
run "up" "make doctor" ./scripts/up.sh
run "Act 0" "make validate shows which part (make doctor)" ./scripts/ansible.sh validate
run "verify" "make verify, then the command it names" ./scripts/verify.sh
url="https://localhost:$(vbal_conf VBAL_PORT_WEB)/#/room"
[ "$(uname -s)" = Darwin ] && [ -z "${NO_OPEN:-}" ] && open "$url" || true
printf '\033[32mshow-ready: green in %ss. The situation room is at %s.\033[0m\n' "$(($(date +%s) - t0))" "$url"
echo "First three commands for the presenter: make drill  (or: make site-down SITE=ams, make promote SITE=dub)"
