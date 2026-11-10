#!/usr/bin/env bash
# scripts/journal.sh open|add|close|id: the drill journal, the one writer.
#   open   start a drill if none is open; print its id
#   add    append one step: a JSON object on stdin ({act, step, target,
#          request_path, http_code, vault_said, duration_ms}); ts (UTC, ms),
#          operator and drill id are added here. Opens a drill if none is.
#   close  close the open drill (make report does)
#   id     print the open drill's id, or nothing
# .build/drill/<id>/journal.jsonl, .build/drill/open, .build/drill/latest.
# vault_said is Vault's errors[0] or status fields, never a token: a value
# shaped like a Vault token is refused.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
D="$BUILD_DIR/drill"
mkdir -p "$D"
now_ms() { perl -MTime::HiRes=time -MPOSIX=strftime -e 'my $t = time; printf "%s.%03dZ", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t - int($t)) * 1000'; }
open_id() {
  if [ -s "$D/open" ]; then cat "$D/open"; return; fi
  local id
  id="drill-$(date -u +%Y%m%d-%H%M%S)"
  mkdir -p "$D/$id"
  printf '%s' "$id" >"$D/open"
  ln -sfn "$id" "$D/latest"
  printf '%s' "$id"
}
case "${1:-}" in
open) open_id; echo ;;
id) [ -s "$D/open" ] && cat "$D/open" && echo || true ;;
add)
  line=$(cat)
  jq -e 'type == "object"' <<<"$line" >/dev/null || die "journal: stdin is not a JSON object"
  if grep -qE '\b(hvs|hvb|hvr)\.[A-Za-z0-9_-]{20,}' <<<"$line"; then die "journal: refusing a line that holds a token-shaped value"; fi
  id=$(open_id)
  # The person who pressed the console's button (the runner sets
  # VBAL_OPERATOR from their verified token), or whoever ran make.
  jq -c --arg ts "$(now_ms)" --arg op "${VBAL_OPERATOR:-${USER:-operator}}" --arg id "$id" \
    '{ts: $ts, drill: $id, operator: $op} + .' <<<"$line" >>"$D/$id/journal.jsonl"
  ;;
close)
  [ -s "$D/open" ] || { echo "journal: no open drill"; exit 0; }
  id=$(cat "$D/open")
  rm -f "$D/open"
  echo "journal: closed $id"
  ;;
*) die "Usage: journal.sh open|add|close|id" ;;
esac
