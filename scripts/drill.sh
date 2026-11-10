#!/usr/bin/env bash
# scripts/drill.sh (make drill): the whole night, act by act, from the roles in
# config/sites.json. A pause between acts for the presenter (DRILL_AUTO=1
# skips them, for the rehearsal). Each act is its own make target; this only
# runs them in order and stops at the first refusal.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
P=$(jq -r '.sites[] | select(.role == "primary") | .id' config/sites.json)
F=$(jq -r '.sites[] | select(.role == "performance") | .id' config/sites.json)
D=$(jq -r '.sites[] | select(.role == "dr") | .id' config/sites.json)
pause() {
  printf '\n\033[1;7m %s \033[0m %s\n' "$1" "$2" >&2
  [ "${DRILL_AUTO:-0}" = 1 ] && return 0
  printf 'Press Enter to run it (Ctrl-C stops the drill here)... ' >&2
  read -r _
}
[ -z "$(./scripts/journal.sh id)" ] || die "drill: a drill is open ($(./scripts/journal.sh id)): make report closes it"
vault_primary || die "drill: no primary"
[ "$VBAL_PRIMARY" = "$P" ] || die "drill: $VBAL_PRIMARY is primary, not $P: finish the last drill (make failback)"
./scripts/journal.sh open >/dev/null

pause "Act I" "$P goes dark (make site-down SITE=$P)"
make --no-print-directory site-down SITE="$P"
pause "Act II" "promote $D with the DR operations token (make promote SITE=$D)"
make --no-print-directory promote SITE="$D"
pause "Act III" "$F follows $D (make repoint SITE=$F TO=$D)"
make --no-print-directory repoint SITE="$F" TO="$D"
pause "Act IV" "fence $P, start it, demote it, unfence it"
make --no-print-directory fence SITE="$P"
make --no-print-directory site-up SITE="$P"
make --no-print-directory demote SITE="$P" TO="$D"
make --no-print-directory unfence SITE="$P"
pause "Act V" "planned failback to $P (make failback)"
make --no-print-directory failback
pause "Epilogue" "the report (make report)"
./scripts/report.sh
