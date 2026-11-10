#!/usr/bin/env bash
# scripts/audit-rotate.sh [--force] (make audit-rotate; make up runs it): keep
# every running Vault's file audit log bounded. The ticker makes every active
# node log two lines four times a second (300 to 450 MB a day, measured), and
# Vault never rotates its own file. A log over 64 MB (or any, with --force)
# is moved to audit.log.1 (the previous .1 is dropped), then Vault gets SIGHUP
# and reopens a fresh audit.log. Not while a drill is open: its report reads
# the current log.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
limit_kb=65536
[ "${1:-}" = --force ] && limit_kb=0
open=$(./scripts/journal.sh id)
[ -z "$open" ] || { echo "audit-rotate: drill $open is open; its report reads the current logs. Skipped."; exit 0; }
n=0
for s in $VBAL_SITES; do
  for h in "seal-$s" $(site_nodes "$s"); do
    c=$(vault_container "$h")
    [ "$(vbal_container_state "$c")" = running ] || continue
    kb=$(podman exec "$c" sh -c 'du -k /vault/audit/audit.log 2>/dev/null | cut -f1' || echo 0)
    [ "${kb:-0}" -gt "$limit_kb" ] || continue
    podman exec "$c" mv /vault/audit/audit.log /vault/audit/audit.log.1
    podman kill --signal HUP "$c" >/dev/null
    n=$((n + 1))
    echo "audit-rotate: $h: $((kb / 1024)) MB moved to audit.log.1, Vault reopened audit.log"
  done
done
[ "$n" -gt 0 ] || echo "audit-rotate: every audit log is under $((limit_kb / 1024)) MB"
