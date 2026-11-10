#!/usr/bin/env bash
# scripts/probe.sh (make probe): prove every replication move the drill
# depends on (prompt 03), on SCRATCH clusters, before prompts 04 to 09 build on
# it. The real sites are not touched: replication is one-way and destructive
# (activating a secondary wipes it), so the probe builds three single-node
# clusters (probe-a, probe-b, probe-c: Shamir 1/1, Raft) and a scratch
# HAProxy, runs the cases, and removes them with their volumes at the end,
# also on failure.
#
# Root tokens of the scratch clusters are used freely: they are scratch and
# are destroyed with them. They live in a private temp dir, never in .build/
# or .secrets/, and are never printed. Writes docs/capabilities.md.
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
# shellcheck source=scripts/probe-lib.sh
source "$VBAL_ROOT/scripts/probe-lib.sh"
cd "$VBAL_ROOT"

OUT="$VBAL_ROOT/docs/capabilities.md"
PRIV=$(mktemp -d)
ROWS="$PRIV/rows.md"
NOTES="$PRIV/notes.md"
: >"$ROWS"
: >"$NOTES"
pass=0
fail=0
note() { printf -- '- %s\n' "$*" | fold -s -w 78 | sed '2,$s/^/  /; s/ *$//' >>"$NOTES"; }
A="https://127.0.0.1:$(vbal_conf VBAL_PORT_PROBE_A)"
B="https://127.0.0.1:$(vbal_conf VBAL_PORT_PROBE_B)"
C="https://127.0.0.1:$(vbal_conf VBAL_PORT_PROBE_C)"
CA_IN=/vault/config/tls/ca-chain.pem
export VBAL_PROBE_HAPROXY_CFG="$PRIV/haproxy.cfg"
: >"$VBAL_PROBE_HAPROXY_CFG"
chmod 644 "$VBAL_PROBE_HAPROXY_CFG"
chmod 755 "$PRIV"

cleanup() {
  set +e
  [ -n "${WRITER:-}" ] && kill "$WRITER" 2>/dev/null
  ./scripts/compose.sh probe down -v --remove-orphans >/dev/null 2>&1
  rm -rf "$PRIV"
}
trap cleanup EXIT
echo "probe: removing leftovers of an earlier run"
./scripts/compose.sh probe down -v --remove-orphans >/dev/null 2>&1 || true
[ -s .secrets/vault/vault.hclic ] || die "probe: no licence (make license)"
./scripts/network.sh

started=$(date +%s)
echo "probe: three scratch clusters"
./scripts/compose.sh probe up -d probe-a probe-b probe-c >/dev/null
declare -A KEY ROOT ADDR=([a]=$A [b]=$B [c]=$C)
for n in a b c; do
  until_ok 60 curl -s -o /dev/null --cacert "$VAULT_CACERT" "${ADDR[$n]}/v1/sys/health" || die "probe-$n does not answer"
  api - PUT "${ADDR[$n]}" sys/init '{"secret_shares":1,"secret_threshold":1}'
  [ "$ST" = 200 ] || die "probe-$n init: HTTP $ST $ERR"
  KEY[$n]=$(jq -r '.keys_base64[0]' <<<"$BODY")
  ROOT[$n]=$(jq -r '.root_token' <<<"$BODY")
  api - PUT "${ADDR[$n]}" sys/unseal "$(jq -n --arg k "${KEY[$n]}" '{key: $k}')"
  until_ok 60 bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --cacert '$VAULT_CACERT' '${ADDR[$n]}/v1/sys/health')\" = 200 ]" ||
    die "probe-$n not active after unseal"
done
RA=${ROOT[a]}
printf '%s' "$RA" >"$PRIV/root-a"

unseal() { api - PUT "${ADDR[$1]}" sys/unseal "$(jq -n --arg k "${KEY[$1]}" '{key: $k}')"; }
repl() { curl -s --max-time 5 --cacert "$VAULT_CACERT" "$1/v1/sys/replication/status" | jq -c '.data // {}'; }
state_is() { repl "$1" | jq -e --arg k "$2" --arg s "$3" '.[$k].state == $s' >/dev/null; }
code_is() { [ "$(health_code "$1")" = "$2" ]; }

# ── P1, P17: licence, generate-root ──────────────────────────────────────────
api "$RA" GET "$A" sys/license/status
features=$(jq -r '.data.autoloaded.features | join(", ")' <<<"$BODY")
expect P1 all "GET sys/license/status" "Performance Replication, DR Replication, Namespaces" 200 \
  '(.data.autoloaded.features | index("Performance Replication")) and (.data.autoloaded.features | index("DR Replication")) and (.data.autoloaded.features | index("Namespaces"))'
api - PUT "$A" sys/generate-root/attempt '{}'
expect P17 2.x "PUT sys/generate-root/attempt (no token)" "refused" "4[0-9][0-9]"
api "$RA" PUT "$A" sys/generate-root/attempt '{}'
expect P17 2.x "PUT sys/generate-root/attempt (token)" "starts" 200 '.started == true'
api "$RA" DELETE "$A" sys/generate-root/attempt

# ── Structure on a, as the platform root would declare it ────────────────────
echo "probe: structure on probe-a (namespaces, KV, AppRole, policies, token roles)"
for ns in payments payments-eu; do api "$RA" POST "$A" "sys/namespaces/$ns"; done
for ns in payments payments-eu; do api "$RA" POST "$A" "$ns/sys/mounts/kv" '{"type":"kv","options":{"version":"2"}}'; done
api "$RA" POST "$A" payments-eu/kv/data/seed '{"data":{"note":"synthetic seed"}}'
api "$RA" POST "$A" payments/sys/auth/approle '{"type":"approle"}'
api "$RA" PUT "$A" payments/sys/policies/acl/vbal-app-ticker \
  "$(jq -n '{policy: "path \"kv/data/*\" { capabilities = [\"create\", \"update\", \"read\"] }"}')"
api "$RA" POST "$A" payments/auth/approle/role/ticker '{"token_type":"batch","token_policies":["vbal-app-ticker"],"token_ttl":"1h"}'
api "$RA" POST "$A" payments/auth/approle/role/ticker-svc '{"token_type":"service","token_policies":["vbal-app-ticker"],"token_ttl":"1h"}'
api "$RA" PUT "$A" sys/policies/acl/vbal-dr-operations "$(jq -n --rawfile p vault/policies/dr-operations.hcl '{policy: $p}')"
api "$RA" POST "$A" auth/token/roles/vbal-dr-operations '{"allowed_policies":["vbal-dr-operations"],"orphan":true,"renewable":false,"token_type":"batch"}'
api "$RA" PUT "$A" sys/policies/acl/probe-ansible \
  "$(jq -n '{policy: "path \"sys/replication/*\" { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"sudo\"] }\npath \"sys/namespaces\" { capabilities = [\"list\", \"read\"] }"}')"
api "$RA" POST "$A" auth/token/roles/probe-ansible-batch '{"allowed_policies":["probe-ansible"],"orphan":true,"renewable":false,"token_type":"batch","token_ttl":"1h"}'
login() { # <addr> <role>: sets LT (or empty) and leaves ST/ERR
  local rid sid
  api "$RA" GET "$A" "payments/auth/approle/role/$2/role-id"
  rid=$(jq -r '.data.role_id' <<<"$BODY")
  api "$RA" POST "$A" "payments/auth/approle/role/$2/secret-id" '{}'
  sid=$(jq -r '.data.secret_id' <<<"$BODY")
  api - POST "$1" payments/auth/approle/login "$(jq -n --arg r "$rid" --arg s "$sid" '{role_id: $r, secret_id: $s}')"
  LT=$(jq -r '.auth.client_token // empty' <<<"$BODY")
}
mint() { # <addr> <root-ish token> <role>: sets MT
  api "$2" POST "$1" "auth/token/create/$3" '{"ttl":"1h"}'
  MT=$(jq -r '.auth.client_token // empty' <<<"$BODY")
}

# ── P2, P3, P4, P5: replication roles and their health codes ─────────────────
echo "probe: replication (a performance + DR primary, b performance, c DR)"
note "Health codes on a single-node cluster before replication: active $(health_code "$A")."
api "$RA" POST "$A" sys/replication/performance/primary/enable '{"primary_cluster_addr":"https://probe-a:8201"}'
expect P3 0 "POST sys/replication/performance/primary/enable" "enabled" "200|204"
api "$RA" POST "$A" sys/replication/dr/primary/enable '{"primary_cluster_addr":"https://probe-a:8201"}'
expect P4 0 "POST sys/replication/dr/primary/enable" "enabled" "200|204"
until_ok 30 code_is "$A" 200 || true
api "$RA" POST "$A" sys/replication/performance/primary/secondary-token '{"id":"b-1"}'
WRAP=$(jq -r '.wrap_info.token' <<<"$BODY")
api - POST "$B" sys/replication/performance/secondary/enable "$(jq -n --arg t "$WRAP" --arg ca "$CA_IN" '{token: $t, ca_file: $ca}')"
expect P3 0 "performance/secondary/enable on b WITHOUT b's root" "refused (2.x)" "4[0-9][0-9]"
t0=$(date +%s)
api "${ROOT[b]}" POST "$B" sys/replication/performance/secondary/enable "$(jq -n --arg t "$WRAP" --arg ca "$CA_IN" '{token: $t, ca_file: $ca}')"
expect P3 0 "performance/secondary/enable on b with b's own root" "activated" "200|204"
until_ok 120 state_is "$B" performance stream-wals || true
note "b (performance secondary) streamed $(( $(date +%s) - t0 ))s after enable."
api "${ROOT[b]}" GET "$B" auth/token/lookup-self
expect P3 0 "b's own root token after activation" "dead (403)" 403
api "$RA" POST "$A" sys/replication/dr/primary/secondary-token '{"id":"c-1"}'
WRAP=$(jq -r '.wrap_info.token' <<<"$BODY")
t0=$(date +%s)
api "${ROOT[c]}" POST "$C" sys/replication/dr/secondary/enable "$(jq -n --arg t "$WRAP" --arg ca "$CA_IN" '{token: $t, ca_file: $ca}')"
expect P4 0 "dr/secondary/enable on c with c's own root" "activated" "200|204"
until_ok 120 state_is "$C" dr stream-wals || true
note "c (DR secondary) streamed $(( $(date +%s) - t0 ))s after enable."
expect_code() { ST=$(health_code "$2"); ERR=""; expect "$1" "$3" "GET sys/health ($4)" "$5" "$5"; }
expect_code P4 "$C" 0 "c, DR secondary" 472
expect_code P5 "$B" 0 "b, performance secondary active" 200
expect_code P2 "$A" 0 "a, primary active" 200
api "$RA" GET "$C" payments/kv/data/x
record P4 0 "GET payments/kv/data/x on c (DR secondary)" "HTTP $ST: $ERR"

# ── P19: unauthenticated status on every role; logins on a DR secondary ──────
for n in a b c; do
  api - GET "${ADDR[$n]}" sys/replication/status
  expect P19 all "GET sys/replication/status on $n (no token)" "answers" 200 '.data.dr.mode != null'
done
login "$C" ticker
record P19 all "AppRole login on c (DR secondary)" "HTTP $ST: $ERR"

# ── P15: paths filter (deny payments-eu for b) ───────────────────────────────
api "$RA" POST "$A" sys/replication/performance/primary/paths-filter/b-1 '{"mode":"deny","paths":["payments-eu/"]}'
expect P15 all "POST .../primary/paths-filter/b-1 mode=deny payments-eu/" "accepted" "200|204"
api "$RA" GET "$A" sys/replication/performance/primary/paths-filter/b-1
record P15 all "GET .../paths-filter/b-1 (shape for Terraform)" "$(jq -c '.data' <<<"$BODY")"
mint "$A" "$RA" probe-ansible-batch
AB=$MT
absent_on_b() { curl -s --cacert "$VAULT_CACERT" -H "X-Vault-Token: $AB" -X LIST "$B/v1/sys/namespaces" | jq -e '(.data.keys // []) | index("payments-eu/") == null and index("payments/") != null' >/dev/null; }
if until_ok 60 absent_on_b; then
  record P15 all "LIST sys/namespaces on b (batch token from a)" "payments/ present, payments-eu/ absent after ${WAITED}s"
else
  api "$AB" LIST "$B" sys/namespaces
  row P15 all "LIST sys/namespaces on b" "payments-eu absent" "HTTP $ST: $(jq -c '.data.keys' <<<"$BODY") $ERR" no
fi

# ── P18, P6: tokens on the performance secondary ─────────────────────────────
login "$A" ticker
TB=$LT
login "$A" ticker-svc
TS=$LT
api "$TB" POST "$B" payments/kv/data/ticker/1 '{"data":{"seq":1}}'
expect P6 0 "write payments/kv/data/ticker/1 on b (batch token from a)" "forwarded to a" "200|204"
api "$RA" GET "$A" payments/kv/data/ticker/1
expect P6 0 "read it back on a" "present" 200 '.data.data.seq == 1'
api "$TB" GET "$B" payments/kv/data/ticker/1
expect P18 0 "read on b with a BATCH AppRole token from a" "works" 200
api "$TS" GET "$B" payments/kv/data/ticker/1
record P18 0 "read on b with a SERVICE AppRole token from a" "HTTP $ST: $ERR"

# ── DR operation tokens, minted BEFORE the primary dies (D9) ─────────────────
mint "$A" "$RA" vbal-dr-operations
DRA=$MT
expect P8 II "POST auth/token/create/vbal-dr-operations on a" "a batch token" 200 '.auth.token_type == "batch" and .auth.orphan == true'
api "$RA" POST "$A" auth/token/create-orphan '{"policies":["vbal-dr-operations"],"ttl":"1h"}'
DRS=$(jq -r '.auth.client_token' <<<"$BODY")

# ── P7, P14 (one run): Amsterdam dies under a 4 writes/s writer ──────────────
echo "probe: writer at 4/s on a, then podman kill"
ACKED="$PRIV/acked"
: >"$ACKED"
(
  seq=0
  while :; do
    seq=$((seq + 1))
    st=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 --cacert "$VAULT_CACERT" -H "X-Vault-Token: $TB" \
      -d "{\"data\":{\"seq\":$seq}}" "$A/v1/payments/kv/data/rpo/$seq" || true)
    [[ "$st" == 20[04] ]] && printf '%s %s\n' "$seq" "$(perl -MTime::HiRes=time -e 'printf "%.3f", time')" >>"$ACKED"
    sleep 0.25
  done
) &
WRITER=$!
sleep 8
t_kill=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
podman kill vbal-probe_a >/dev/null
sleep 2
kill "$WRITER" 2>/dev/null || true
WRITER=""
acked=$(wc -l <"$ACKED" | tr -d ' ')
api "$TB" GET "$B" payments/kv/data/ticker/1
record P7 I "read on b while a is down" "HTTP $ST${ERR:+: $ERR}"
api "$TB" POST "$B" payments/kv/data/ticker/2 '{"data":{"seq":2}}'
record P7 I "write on b while a is down" "HTTP $ST: $ERR"
login "$B" ticker 2>/dev/null || true
record P7 I "AppRole login on b while a is down" "HTTP $ST${ERR:+: $ERR}"

# ── P8, P9: promote c with the DR operation token ────────────────────────────
api - GET "$C" sys/storage/raft/autopilot/state
record P9 II "GET sys/storage/raft/autopilot/state on c, no token" "HTTP $ST: $ERR"
api "$DRS" GET "$C" sys/storage/raft/autopilot/state
record P9 II "same, SERVICE token with vbal-dr-operations (from a)" "HTTP $ST${ERR:+: $ERR}"
api "$DRA" GET "$C" sys/storage/raft/autopilot/state
expect P8 II "same, BATCH DR operation token (from a)" "accepted" 200
api - POST "$C" sys/replication/dr/secondary/promote '{"primary_cluster_addr":"https://probe-c:8201"}'
expect P8 II "dr/secondary/promote on c WITHOUT a token" "refused" "4[0-9][0-9]"
t_promote=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
api "$DRA" POST "$C" sys/replication/dr/secondary/promote '{"primary_cluster_addr":"https://probe-c:8201"}'
if [[ "$ST" =~ ^20[04]$ ]]; then
  expect P8 II "dr/secondary/promote on c (X-Vault-Token: DR batch token)" "promoted" "200|204"
  note "The DR batch token goes in the X-Vault-Token header; no dr_operation_token body field is needed on 2.2.1."
else
  first="HTTP $ST: $ERR"
  api - POST "$C" sys/replication/dr/secondary/promote "$(jq -n --arg t "$DRA" '{dr_operation_token: $t, primary_cluster_addr: "https://probe-c:8201"}')"
  expect P8 II "dr/secondary/promote on c (dr_operation_token in the body; header gave: $first)" "promoted" "200|204"
fi
until_ok 120 code_is "$C" 200 || true
note "c answered 200 ${WAITED}s after the promote call; $(perl -e "printf '%.1f', $t_promote - $t_kill")s passed between the kill and the promote call (scripted)."
missing=0
while read -r s _; do
  api "$RA" GET "$C" "payments/kv/data/rpo/$s"
  [ "$ST" = 200 ] || missing=$((missing + 1))
done <"$ACKED"
record P14 all "acknowledged writes missing on promoted c (one run, 4/s, podman kill)" "$missing of $acked missing"
note "RPO, one probe run: $missing of $acked acknowledged writes missing. The ten-run measurement is prompt 06's make drill-runs."
api "$TB" GET "$C" payments/kv/data/ticker/1
expect P18 II "read on promoted c with the BATCH AppRole token from a" "works" 200
api "$RA" GET "$C" auth/token/lookup-self
expect P18 II "a's root token on promoted c (DR replicates the token store)" "valid" 200
record P2 II "replication modes of promoted c" "$(repl "$C" | jq -c '{perf: .performance.mode, dr: .dr.mode}')"

# ── P10: Frankfurt follows (update-primary on the performance secondary) ─────
# A performance secondary learns the DR secondaries' cluster addresses from
# its primary (known_primary_cluster_addrs), so after a DR promotion it can
# reconnect to the promoted cluster on its own. update-primary is then a
# fallback: on a secondary already attached to the target it fails with
# "error authing for bootstrap" and burns the activation token.
follows_c() { repl "$B" | jq -e '.performance.state == "stream-wals" and ([.performance.primaries[]? | .api_address] | index("https://probe-c:8200") != null)' >/dev/null; }
if until_ok 60 follows_c; then
  record P10 III "b follows promoted c on its own, without update-primary" \
    "after ${WAITED}s (from the promote call): $(repl "$B" | jq -c '{state: .performance.state, primaries: [.performance.primaries[]? | .api_address], known: .performance.known_primary_cluster_addrs}')"
  note "Frankfurt followed the promoted cluster on its own ${WAITED}s after the promote call: Act III is a wait, update-primary only a fallback."
else
  api "$RA" POST "$C" sys/replication/performance/primary/secondary-token '{"id":"b-2"}'
  WRAP=$(jq -r '.wrap_info.token // empty' <<<"$BODY")
  mint "$C" "$RA" probe-ansible-batch
  api "$MT" POST "$B" sys/replication/performance/secondary/update-primary "$(jq -n --arg t "$WRAP" --arg ca "$CA_IN" '{token: $t, ca_file: $ca}')"
  expect P10 III "b did not follow within 60s: update-primary with a BATCH token minted on c" "accepted" "200|204"
fi
upd_b() { api "$1" POST "$B" sys/replication/performance/secondary/update-primary "$(jq -n --arg t "${2:-x}" --arg ca "$CA_IN" '{token: $t, ca_file: $ca}')"; }
upd_b -
record P10 III "update-primary on b, no token (authorisation only)" "HTTP $ST: $ERR"
upd_b "$RA"
record P10 III "update-primary on b, SERVICE token from a (authorisation only)" "HTTP $ST${ERR:+: $ERR}"
api "$TB" POST "$B" payments/kv/data/ticker/3 '{"data":{"seq":3}}'
expect P10 III "write on b after it follows c" "forwarded to c" "200|204"

# ── P11: the ghost returns un-fenced ─────────────────────────────────────────
podman start vbal-probe_a >/dev/null
until_ok 60 curl -s -o /dev/null --cacert "$VAULT_CACERT" "$A/v1/sys/health" || true
unseal a
until_ok 60 code_is "$A" 200 || true
record P11 IV "sys/health: a (returned) and c (promoted)" "a $(health_code "$A"), c $(health_code "$C"); a says $(repl "$A" | jq -c '{perf: .performance.mode, dr: .dr.mode}')"
note "Split brain is real: the returned a answers 200 and calls itself primary while c does too. Only the fence keeps it out of the front door."

# ── P12: demote a, attach it to c as a DR secondary ──────────────────────────
api "$RA" POST "$A" sys/replication/dr/primary/demote '{}'
expect P12 IV "dr/primary/demote on a" "demoted" "200|204"
api "$RA" POST "$A" sys/replication/performance/primary/demote '{}'
record P12 IV "performance/primary/demote on a" "HTTP $ST${ERR:+: $ERR}"
sleep 3
record P2 IV "a after demote: health and modes" "$(health_code "$A"); $(repl "$A" | jq -c '{perf: .performance.mode, dr: .dr.mode, dr_state: .dr.state}')"
api "$RA" POST "$C" sys/replication/dr/primary/secondary-token '{"id":"a-1"}'
WRAP=$(jq -r '.wrap_info.token // empty' <<<"$BODY")
dr_upd() { api "$2" POST "$1" sys/replication/dr/secondary/update-primary "$(jq -n --arg t "$WRAP" --arg ca "$CA_IN" '{token: $t, ca_file: $ca}')"; }
dr_upd "$A" "$DRA"
record P20 IV "dr update-primary on demoted a, DR token minted on a before it died" "HTTP $ST${ERR:+: $ERR}"
if ! [[ "$ST" =~ ^20[04]$ ]]; then
  mint "$C" "$RA" vbal-dr-operations
  DRC=$MT
  dr_upd "$A" "$DRC"
  expect P20 IV "dr update-primary on demoted a, DR token minted on c" "accepted" "200|204"
fi
t0=$(date +%s)
until_ok 180 state_is "$A" dr stream-wals || true
note "a streamed from c as DR secondary $(( $(date +%s) - t0 ))s after update-primary."
expect_code P12 "$A" IV "a, now c's DR secondary" 472

# ── P13, P20: planned failback (c back to DR secondary, a primary) ──────────
for i in $(seq 1 20); do api "$RA" POST "$C" "payments/kv/data/failback/$i" "{\"data\":{\"i\":$i}}"; done
caught_up() {
  local p s
  p=$(repl "$C" | jq -r '.dr.last_wal // 0')
  s=$(repl "$A" | jq -r '.dr.last_remote_wal // 0')
  [ "$s" -ge "$p" ] && [ "$p" -gt 0 ]
}
until_ok 60 caught_up || true
record P13 V "a's last_remote_wal caught up with c's last_wal" "after ${WAITED}s"
api "$RA" POST "$C" sys/replication/dr/primary/demote '{}'
expect P13 V "dr/primary/demote on c" "demoted" "200|204"
api "$RA" POST "$C" sys/replication/performance/primary/demote '{}'
record P13 V "performance/primary/demote on c" "HTTP $ST${ERR:+: $ERR}"
DRC=${DRC:-}
if [ -z "$DRC" ]; then
  mint "$C" "$RA" vbal-dr-operations 2>/dev/null || true
  DRC=$MT
fi
api "$DRA" POST "$A" sys/replication/dr/secondary/promote '{"primary_cluster_addr":"https://probe-a:8201"}'
record P20 V "promote a with the DR token minted on a before it died" "HTTP $ST${ERR:+: $ERR}"
if ! [[ "$ST" =~ ^20[04]$ ]]; then
  api "$DRC" POST "$A" sys/replication/dr/secondary/promote '{"primary_cluster_addr":"https://probe-a:8201"}'
  expect P20 V "promote a with a DR token minted on c" "promoted" "200|204"
fi
until_ok 120 code_is "$A" 200 || true
lost=0
for i in $(seq 1 20); do
  api "$RA" GET "$A" "payments/kv/data/failback/$i"
  [ "$ST" = 200 ] || lost=$((lost + 1))
done
ST=$lost
ERR=""
expect P13 V "writes made on c before the planned failback, missing on a" "0 of 20" 0
mint "$A" "$RA" vbal-dr-operations
DRA2=$MT
api "$RA" POST "$A" sys/replication/dr/primary/secondary-token '{"id":"c-2"}'
WRAP=$(jq -r '.wrap_info.token // empty' <<<"$BODY")
dr_upd "$C" "$DRA2"
expect P13 V "c re-attached as a's DR secondary (DR token minted on a)" "accepted" "200|204"
follows_a() { repl "$B" | jq -e '.performance.state == "stream-wals" and ([.performance.primaries[]? | .api_address] | index("https://probe-a:8200") != null)' >/dev/null; }
if until_ok 60 follows_a; then
  record P13 V "b follows a on its own after the failback promote" "after ${WAITED}s"
else
  api "$RA" POST "$A" sys/replication/performance/primary/secondary-token '{"id":"b-3"}'
  WRAP=$(jq -r '.wrap_info.token // empty' <<<"$BODY")
  mint "$A" "$RA" probe-ansible-batch
  upd_b "$MT" "$WRAP"
  expect P13 V "b did not follow within 60s: repointed to a (batch token minted on a)" "accepted" "200|204"
fi
until_ok 180 state_is "$C" dr stream-wals || true
until_ok 180 state_is "$B" performance stream-wals || true
record P13 V "roles after failback" "a $(repl "$A" | jq -c '{perf: .performance.mode, dr: .dr.mode}'), b $(repl "$B" | jq -r '.performance.mode'), c $(repl "$C" | jq -r '.dr.mode')"

# ── P16: Terraform against the scratch primary ───────────────────────────────
echo "probe: Terraform scratch root (namespace, namespaced provider, paths filter, audit)"
api "$RA" POST "$A" sys/replication/performance/primary/paths-filter/b-3 '{"mode":"deny","paths":["payments-eu/"]}'
tfp() { VBAL_PROBE_ROOT_FILE="$PRIV/root-a" ./scripts/tf.sh probe "$@" -no-color >"$PRIV/tf.log" 2>&1; }
if tfp apply && tfp apply; then
  rc=0
  tfp plan || rc=$?
  ST=$rc
  ERR=""
  expect P16 Terraform "apply twice, then plan -detailed-exitcode" "0 (no diff)" 0
else
  row P16 Terraform "terraform apply" "applies" "$(grep -m1 -E 'Error' "$PRIV/tf.log" || tail -1 "$PRIV/tf.log")" no
fi
VBAL_PROBE_ROOT_FILE="$PRIV/root-a" ./scripts/tf.sh probe destroy -no-color >/dev/null 2>&1 || true
rm -rf .secrets/terraform/probe

# ── P21: is a fence on the runtime socket durable? ───────────────────────────
echo "probe: HAProxy fence durability"
haproxy_cfg() { # <server options>
  cat >"$VBAL_PROBE_HAPROXY_CFG" <<CFG
global
  stats socket ipv4@127.0.0.1:9999 level admin
defaults
  mode http
  timeout connect 2s
  timeout client 5s
  timeout server 5s
frontend fe
  bind 127.0.0.1:8443
  default_backend be
backend be
  option httpchk GET /v1/sys/health
  http-check expect status 200
  server a probe-a:8200 check ssl verify required ca-file /etc/haproxy/ca.pem inter 1s $1
CFG
}
hap() { podman exec vbal-probe_haproxy sh -c "echo '$1' | nc 127.0.0.1 9999"; }
admin_state() { hap "show servers state be" | awk '$4 == "a" {print $7}'; }
haproxy_cfg ""
./scripts/compose.sh probe up -d haproxy >/dev/null
until_ok 30 hap "show info" || true
hap "disable server be/a" >/dev/null
record P21 IV "admin state after disable server on the runtime socket" "srv_admin_state=$(admin_state)"
podman restart vbal-probe_haproxy >/dev/null
until_ok 30 hap "show info" || true
record P21 IV "admin state after podman restart (runtime fence only)" "srv_admin_state=$(admin_state) (0 = back in rotation)"
haproxy_cfg "disabled"
podman restart vbal-probe_haproxy >/dev/null
until_ok 30 hap "show info" || true
record P21 IV "admin state after restart with disabled rendered in the config" "srv_admin_state=$(admin_state)"

# ── docs/capabilities.md ─────────────────────────────────────────────────────
seconds=$(($(date +%s) - started))
version=$(curl -s --cacert "$VAULT_CACERT" "$A/v1/sys/health" | jq -r .version)
# The drill's measurements (make drill-runs) live below the probe's rows: keep them.
measured=$(sed -n '/^## Measured/,$p' "$OUT" 2>/dev/null || true)
{
  echo "# Capabilities"
  echo
  { echo "Generated by \`make probe\` (prompt 03) on $(date -u +%Y-%m-%d) against Vault $version"
    echo "on scratch clusters (probe-a, probe-b, probe-c). $pass passed, $fail failed, ${seconds}s."
    echo "Licence features: $features."; } | tr '\n' ' ' | fold -s -w 78 | sed 's/ *$//'
  echo
  echo
  echo "Every answer is Vault's own (HTTP status and \`errors[0]\` verbatim). The"
  echo "drill (prompts 05 and 06) builds on these rows, never on the docs or memory."
  echo
  echo "| Case | Act | Call | Expected | Vault said | Pass |"
  echo "| --- | --- | --- | --- | --- | --- |"
  cat "$ROWS"
  echo
  echo "## Notes and timings"
  echo
  cat "$NOTES"
  if [ -n "$measured" ]; then
    echo
    echo "$measured"
  fi
} >"$OUT"
echo
info "probe: $pass passed, $fail failed in ${seconds}s; wrote docs/capabilities.md"
[ "$fail" -eq 0 ]
