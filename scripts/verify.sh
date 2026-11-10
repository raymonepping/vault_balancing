#!/usr/bin/env bash
# scripts/verify.sh [section...]: end-to-end checks of the running lab.
# Read-only. Sections: podman seals sites replication frontdoor ticker api
# identity boundary (default: all that are built). The browser-level checks are
# Playwright's: make test-ui.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"

pass=0
fail=0
ok() {
  printf '  \033[32m✓\033[0m %s\n' "$*"
  pass=$((pass + 1))
}
bad() {
  printf '  \033[31m✗\033[0m %s\n' "$*"
  fail=$((fail + 1))
}
check() {
  local msg=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$msg"; else bad "$msg"; fi
}
native() { # <image>: pulled and the host's architecture, not emulated
  [ "$(podman image inspect "$1" --format '{{.Architecture}}' 2>/dev/null)" = "$(podman info --format '{{.Host.Arch}}')" ]
}
health_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/sys/health" || true; }

section_podman() {
  echo "podman"
  check "Podman machine answers" podman info
  check "network vbal-internal exists" podman network exists vbal-internal
  check "Vault Enterprise image is native arm64" native "$(vbal_conf VAULT_ENT_IMAGE)"
  local skew=99 vm
  vm=$(podman machine ssh date +%s 2>/dev/null | tr -d '\r' | tail -1 || true)
  [ -n "$vm" ] && skew=$(($(date +%s) - vm)) && skew=${skew#-}
  [ "$skew" -le 5 ] && ok "VM clock within 5s of the host (${skew}s)" || bad "VM clock off by ${skew}s (make clock-sync)"
  local leftover
  leftover=$(podman ps -a --filter name=^vbal-probe --format '{{.Names}}' | tr '\n' ' ')
  [ -z "${leftover// /}" ] && ok "no probe leftovers" || bad "probe leftovers: $leftover"
}

section_seals() {
  echo "seals"
  local s state
  for s in $VBAL_SITES; do
    if [ "$(vbal_container_state "$(vault_container "seal-$s")")" != running ]; then
      bad "seal-$s is not running (a site that is down in a drill shows here too)"
      continue
    fi
    vault_node "seal-$s"
    state=$(vault_json 2>/dev/null || echo '{}')
    jq -e '.initialized and (.sealed | not) and .type == "shamir"' <<<"$state" >/dev/null &&
      ok "seal-$s initialised, unsealed, Shamir" || bad "seal-$s is not unsealed (make unseal SITE=$s)"
    check "seal-$s: tf-seal-$s token accepted" bash -c "source scripts/common.sh; vault_node seal-$s; vault_token tf-seal-$s; vault token lookup"
    check "seal-$s: Transit key autounseal exists" bash -c "source scripts/common.sh; vault_node seal-$s; vault_token ansible-seal-$s; vault read transit/keys/autounseal"
  done
  check "every node's seal token accepted by its seal Vault" scripts/seal-token-status.sh
  local f
  f=$(find .secrets/vault -name '*-init.json' ! -perm 600 2>/dev/null | head -1)
  [ -z "$f" ] && ok "init files are 0600" || bad "$f is not 0600"
}

section_sites() {
  echo "sites"
  local s n code sealed_type up
  for s in $VBAL_SITES; do
    up=0
    for n in $(site_nodes "$s"); do
      [ "$(vbal_container_state "$(vault_container "$n")")" = running ] || continue
      vault_node "$n"
      code=$(health_code)
      sealed_type=$(vault_json 2>/dev/null | jq -r '"\(.sealed) \(.type)"' || echo "? ?")
      if [ "$sealed_type" = "false transit" ]; then up=$((up + 1)); else bad "$n: sealed or not Transit-sealed ($sealed_type, HTTP $code)"; fi
    done
    [ "$up" -ge 1 ] && ok "$s: $up node(s) unsealed through seal-$s (Transit)" || bad "$s: no node unsealed"
  done
  check "the primary answers and ansible-platform is accepted there" bash -c 'source scripts/common.sh; vault_primary >/dev/null; vault_token ansible-platform; vault token lookup'
  check "no init root token survives on the primary" bash -c "! jq -e '.root_token' .secrets/vault/vault-$(node scripts/sites.js primary)-init.json"
  check "the primary has $(jq '.sites[0].nodes' config/sites.json) Raft voters" bash -c '
    source scripts/common.sh; vault_primary >/dev/null; vault_token ansible-platform
    [ "$(vault read -format=json sys/storage/raft/configuration | jq "[.data.config.servers[] | select(.voter)] | length")" = 3 ]'
}

section_replication() {
  echo "replication"
  local p f d
  p=$(replication_status "$(node scripts/sites.js primary)")
  f=$(replication_status fra)
  d=$(replication_status dub)
  jq -e '.performance.mode == "primary" and .dr.mode == "primary"' <<<"$p" >/dev/null &&
    ok "the bootstrap primary is performance and DR primary" || bad "the bootstrap primary is not primary of both kinds (a drill open? make failback)"
  jq -e '.performance.mode == "secondary" and .performance.state == "stream-wals"' <<<"$f" >/dev/null &&
    ok "fra streams as performance secondary" || bad "fra is not streaming as performance secondary"
  jq -e '.dr.mode == "secondary" and .dr.state == "stream-wals"' <<<"$d" >/dev/null &&
    ok "dub streams as DR secondary" || bad "dub is not streaming as DR secondary"
  local lag
  lag=$(jq -n --argjson p "$p" --argjson f "$f" '($p.performance.last_wal // 0) - ($f.performance.last_remote_wal // 0)')
  [ "$lag" -le 100 ] && ok "fra is within 100 WAL entries of the primary ($lag)" || bad "fra lags $lag WAL entries"
  check "the DR operations token is valid for more than 2h" bash -c '
    m=.secrets/vault/dr-operation-token.meta.json; [ -s "$m" ] && [ $(( $(jq .expires_at "$m") - $(date +%s) )) -gt 7200 ]'
}

section_frontdoor() {
  echo "frontdoor"
  local csv up_p up_r
  if ! csv=$(curl -sf --max-time 3 "http://127.0.0.1:$(vbal_conf VBAL_PORT_STATS)/stats;csv"); then
    bad "HAProxy stats do not answer (make frontdoor-up)"
    return
  fi
  up_p=$(grep -c '^primary,vault-.*,UP,' <<<"$csv" || true)
  up_r=$(grep -c '^regional,vault-.*,UP,' <<<"$csv" || true)
  [ "$up_p" = 1 ] && ok "writes: exactly one server up (the primary's active node)" || bad "writes: $up_p servers up (make frontdoor-status)"
  [ "$up_r" = 3 ] && ok "reads: Frankfurt's three nodes up" || bad "reads: $up_r servers up"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$VAULT_CACERT" "https://127.0.0.1:$(vbal_conf VBAL_PORT_FRONTDOOR)/v1/sys/health" || true)
  [ "$code" = 200 ] && ok "the front door answers 200 with Vault's own certificate" || bad "the front door answers $code"
}

section_ticker() {
  echo "ticker"
  local m
  if ! m=$(podman exec vbal-ticker node -e "fetch('http://127.0.0.1:9100/metrics').then(r=>r.text()).then(t=>process.stdout.write(t))" 2>/dev/null); then
    bad "the ticker does not answer (make app-up)"
    return
  fi
  jq -e '.acked_10s >= 36 and .fail_10s == 0' <<<"$m" >/dev/null &&
    ok "the ticker writes 4/s through the front door ($(jq .acked_10s <<<"$m") in 10s)" || bad "the ticker: $(jq -c '{acked_10s, fail_10s}' <<<"$m")"
  jq -e '.regional_lag != null and .regional_lag <= 4' <<<"$m" >/dev/null &&
    ok "Frankfurt is within 4 writes (lag $(jq .regional_lag <<<"$m"))" || bad "Frankfurt lag: $(jq -c '{regional_lag, regional_error}' <<<"$m")"
}

section_api() {
  echo "api"
  local base r
  base="https://127.0.0.1:$(vbal_conf VBAL_PORT_API)"
  if ! r=$(curl -sf --max-time 5 --cacert "$VAULT_CACERT" "$base/healthz"); then
    bad "the API does not answer (make web-up)"
    return
  fi
  jq -e '.ok' <<<"$r" >/dev/null && ok "API healthz ok" || bad "API healthz: failed $(jq -c .failed <<<"$r")"
  local p
  for p in sites frontdoor ticker drill drills layers; do
    check "GET /api/$p answers" curl -sf --max-time 5 --cacert "$VAULT_CACERT" "$base/api/$p"
  done
  [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST --cacert "$VAULT_CACERT" "$base/api/sites")" = 405 ] && ok "the API refuses writes (405)" || bad "POST /api/sites is not 405"
  local roles
  roles=$(curl -sf --max-time 5 --cacert "$VAULT_CACERT" "$base/api/sites" | jq -r '[.[].data.role] | join(",")' || true)
  [ "$roles" = "primary,performance secondary,DR secondary" ] && ok "the API reports Vault's roles ($roles)" || bad "the API reports roles: $roles"
  check "an SSE snapshot arrives" bash -c "curl -sN --max-time 3 --cacert '$VAULT_CACERT' '$base/api/events' | grep -m1 -q '^event: snapshot'"
}

section_identity() {
  echo "identity"
  local kc
  kc="http://127.0.0.1:$(vbal_conf VBAL_PORT_KEYCLOAK)/realms/balancing"
  check "OpenLDAP answers" podman exec vbal-openldap sh -c 'ldapsearch -x -H ldap://localhost -D cn=admin,dc=balancing,dc=lab -w "$(cat /run/secrets/ldap-admin-password)" -b dc=balancing,dc=lab -s base'
  check "keycloak-bind can read the people (the federation)" bash -c "podman exec vbal-openldap sh -c 'ldapsearch -x -LLL -H ldap://localhost -D cn=keycloak-bind,ou=system,dc=balancing,dc=lab -w \"\$(cat /run/secrets/system/keycloak-bind)\" -b ou=people,dc=balancing,dc=lab uid' | grep -c '^uid:' | grep -qx 3"
  check "Keycloak realm balancing answers" curl -sf --max-time 5 "$kc/.well-known/openid-configuration"
  check "the drill runner runs (make runner-status)" ./scripts/runner.sh status
  local a
  a=$(curl -sf --max-time 5 --cacert "$VAULT_CACERT" "https://127.0.0.1:$(vbal_conf VBAL_PORT_API)/api/actions" || echo '{}')
  jq -e '.runner and .next.id and (.next.enabled == false)' <<<"$a" >/dev/null &&
    ok "signed out, the next step ($(jq -r .next.id <<<"$a")) shows and its button is off" || bad "GET /api/actions: $(jq -c '{runner, next: .next.id, enabled: .next.enabled}' <<<"$a")"
  [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST --cacert "$VAULT_CACERT" "https://127.0.0.1:$(vbal_conf VBAL_PORT_API)/api/actions/site-down")" = 401 ] &&
    ok "an anonymous POST to a drill step is refused (401)" || bad "an anonymous POST to a drill step is not 401"
}

section_boundary() {
  echo "boundary"
  check "every scoped token holds its boundary (make boundary)" scripts/boundary-check.sh
}

all="podman seals sites replication frontdoor ticker api identity boundary"
sections=${*:-$all}
for s in $sections; do
  if declare -F "section_$s" >/dev/null; then
    "section_$s"
  else
    echo "$s"
    echo "  - not built yet"
  fi
done

echo
echo "verify: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
