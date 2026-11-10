#!/usr/bin/env bash
# scripts/doctor.sh (make doctor): read-only. Every line is ok, warn or fail,
# with the make target that fixes it. Nothing here changes the lab.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
fails=0
warns=0
ok() { printf '  \033[32mok  \033[0m %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  \033[31mfail\033[0m %s\n' "$*"; fails=$((fails + 1)); }
now=$(date +%s)

echo "host"
mem=$(( $(podman info --format '{{.Host.MemTotal}}') / 1073741824 ))
[ "$mem" -ge 16 ] && ok "Podman machine: ${mem} GiB, $(podman info --format '{{.Host.CPUs}}') CPUs" || fail "Podman machine has ${mem} GiB; 16 needed (podman machine set --memory)"
free=$(df -Pk "$HOME" | awk 'NR==2 {print int($4 / 1048576)}')  # -P/-k: the same on macOS and Linux
[ "$free" -ge 20 ] && ok "Mac disk: ${free} GiB free" || { [ "$free" -ge 8 ] && warn "Mac disk: ${free} GiB free (a full disk breaks the VM's storage)" || fail "Mac disk: ${free} GiB free: free space before anything else"; }
vm=$(podman machine ssh date +%s 2>/dev/null | tr -d '\r' | tail -1 || true)
if [ -n "$vm" ]; then
  skew=$((now - vm)); skew=${skew#-}
  [ "$skew" -le 5 ] && ok "VM clock within ${skew}s of the Mac" || fail "VM clock ${skew}s off: make clock-sync (TTLs and lag in seconds depend on it)"
else warn "could not read the VM clock (podman machine ssh)"; fi

echo "containers"
down=0
for c in $(for s in $VBAL_SITES; do for h in "seal-$s" $(site_nodes "$s"); do echo "$(vault_container "$h")"; done; done) vbal-haproxy vbal-ticker_agent vbal-ticker vbal-api vbal-web vbal-openldap vbal-keycloak; do
  st=$(vbal_container_state "$c")
  [ "$st" = running ] || { fail "$c is $st: make up"; down=$((down + 1)); }
done
[ "$down" -eq 0 ] && ok "every vbal- container is running (19)"
./scripts/runner.sh status >/dev/null 2>&1 && ok "the drill runner runs (the console's buttons)" || warn "the drill runner is not running: make runner-up (the terminal still works)"
left=$(podman ps -a --filter name=^vbal-probe --format '{{.Names}}' | tr '\n' ' ')
[ -z "${left// /}" ] && ok "no probe leftovers" || warn "probe leftovers: $left (make probe removes them at its end; podman rm them)"
exited=$(podman ps -a --filter name=^vbal- --filter status=exited --format '{{.Names}}' | tr '\n' ' ')
[ -z "${exited// /}" ] && ok "no exited vbal- container" || warn "exited: $exited"

echo "sites"
for s in $VBAL_SITES; do
  vault_node "seal-$s"
  if vault_json 2>/dev/null | jq -e '.sealed | not' >/dev/null; then ok "seal-$s unsealed"; else fail "seal-$s sealed or down: make unseal SITE=$s (then make up)"; fi
  up=0
  for n in $(site_nodes "$s"); do
    vault_node "$n"
    vault_json 2>/dev/null | jq -e '.initialized and (.sealed | not)' >/dev/null && up=$((up + 1))
  done
  [ "$up" -ge 2 ] && ok "$s: $up of 3 nodes unsealed (quorum)" || fail "$s: $up of 3 nodes unsealed, no quorum: make up"
  rep=$(replication_status "$s")
  case "$(jq -r '"\(.dr.mode)/\(.performance.mode)/\(.dr.state // "")/\(.performance.state // "")"' <<<"$rep")" in
  primary/*) ok "$s is primary" ;;
  */secondary/*/stream-wals) ok "$s streams as performance secondary" ;;
  secondary/*/stream-wals/*) ok "$s streams as DR secondary" ;;
  *) warn "$s replication: $(jq -c '{dr: .dr.mode, dr_state: .dr.state, perf: .performance.mode, perf_state: .performance.state}' <<<"$rep") (a drill open? make failback)" ;;
  esac
done

echo "front door"
if csv=$(curl -sf --max-time 3 "http://127.0.0.1:$(vbal_conf VBAL_PORT_STATS)/stats;csv"); then
  up_p=$(grep -c '^primary,vault-.*,UP,' <<<"$csv" || true)
  [ "$up_p" = 1 ] && ok "writes: one server up" || fail "writes: $up_p servers up (make frontdoor-status)"
  maint=$(grep -c ',MAINT' <<<"$csv" || true)
  [ "$maint" = 0 ] && ok "no server fenced" || warn "$maint server(s) fenced (make unfence SITE=<site> when the drill is done)"
else fail "HAProxy stats do not answer: make frontdoor-up"; fi

echo "credentials"
meta="$VBAL_STATE/dr-operation-token.meta.json"
if [ -s "$meta" ]; then
  left=$(( $(jq .expires_at "$meta") - now ))
  [ "$left" -gt 7200 ] && ok "DR operations token: $((left / 3600))h left, from $(jq -r .site "$meta")" || fail "DR operations token: $((left / 60)) min left: make dr-token"
else fail "no DR operations token: make dr-token"; fi
if ./scripts/seal-token-status.sh >/dev/null 2>&1; then ok "every seal token accepted, more than a day left"; else fail "a seal token is rejected or expires within a day: make seal-token-status"; fi
vault_primary 2>/dev/null && vault_token ansible-platform 2>/dev/null
if [ -s .secrets/approle/ticker/secret-id ] && sid=$(vault write -format=json payments/auth/approle/role/ticker/secret-id/lookup secret_id=@.secrets/approle/ticker/secret-id 2>/dev/null); then
  left=$(( $(jq -r '.data.expiration_time[:19] + "Z" | fromdateiso8601' <<<"$sid") - now ))
  [ "$left" -gt 21600 ] && ok "ticker secret-id: $((left / 3600))h left" || warn "ticker secret-id: $((left / 3600))h left: make up re-issues it"
else warn "could not look up the ticker's secret-id (make replicate re-issues it)"; fi
lic=$(vault read -format=json sys/license/status 2>/dev/null | jq -r '.data.autoloaded.expiration_time[:10]' || true)
unset VAULT_TOKEN
[ -n "$lic" ] && ok "licence expires $lic" || warn "could not read the licence (make license-features)"

echo "drill"
open=$(./scripts/journal.sh id)
[ -z "$open" ] && ok "no drill open" || warn "drill $open is open: finish it (make failback) and close it (make report)"
for c in $(for s in $VBAL_SITES; do for n in $(site_nodes "$s"); do echo "$(vault_container "$n")"; done; done); do
  [ "$(vbal_container_state "$c")" = running ] || continue
  kb=$(podman exec "$c" sh -c 'du -k /vault/audit/audit.log 2>/dev/null | cut -f1' || echo 0)
  [ "${kb:-0}" -lt 131072 ] || warn "$c audit log is $((kb / 1024)) MB: make audit-rotate (make up does it daily)"
done
ok "audit logs checked"

echo
[ "$fails" -eq 0 ] && info "doctor: $warns warning(s), nothing failing" || die "doctor: $fails failing, $warns warning(s)"
