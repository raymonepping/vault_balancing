#!/usr/bin/env bash
# scripts/runner.sh up|down|status (make runner-up, runner-down, runner-status):
# the host-side drill runner (scripts/runner.js, D16), a background Node
# process on 127.0.0.1. Its pid is in .build/runner.pid, its log in
# .build/logs/runner.log. Idempotent.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
pidf="$BUILD_DIR/runner.pid"
port=$(vbal_conf VBAL_PORT_RUNNER)
# The pid must still be the runner: after a reboot macOS hands it to another
# process, which `down` would otherwise kill.
alive() { [ -s "$pidf" ] && [[ "$(/bin/ps -p "$(cat "$pidf")" -o command= 2>/dev/null)" == *scripts/runner.js* ]]; }
case "${1:-status}" in
up)
  if alive; then
    echo "runner: already running (pid $(cat "$pidf"), 127.0.0.1:$port)"
    exit 0
  fi
  [ -s .secrets/identity/runner-secret ] || die "runner: no secret: run make identity-up"
  mkdir -p "$BUILD_DIR/logs"
  nohup node scripts/runner.js >>"$BUILD_DIR/logs/runner.log" 2>&1 &
  echo $! >"$pidf"
  for _ in $(seq 1 20); do
    curl -s -o /dev/null "http://127.0.0.1:$port/status" && break
    sleep 0.3
  done
  alive || die "runner: did not start (.build/logs/runner.log)"
  echo "runner: started (pid $(cat "$pidf"), 127.0.0.1:$port)"
  ;;
down)
  if alive; then
    kill "$(cat "$pidf")"
    echo "runner: stopped"
  else echo "runner: not running"; fi
  rm -f "$pidf"
  ;;
status)
  if alive; then echo "runner: running (pid $(cat "$pidf"), 127.0.0.1:$port)"; else
    echo "runner: not running (make runner-up)"
    exit 1
  fi
  ;;
*) die "Usage: runner.sh up|down|status" ;;
esac
