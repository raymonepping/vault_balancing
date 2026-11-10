#!/usr/bin/env bash
# scripts/common.sh: shared, host-side helpers. Source, do not execute.
#
# Host tooling talks to the Vault nodes on their published loopback ports and
# verifies TLS against the lab CA; nothing here uses -tls-skip-verify.
# No helper here uses a root token: after bootstrap there is none (D6).
#
# Names: a site is ams, fra or dub (config/sites.json). Its seal Vault is
# seal-<site>; its nodes are vault-<site>-<n>. A "cluster" (for init files
# and tokens) is seal-<site> or vault-<site>.
# shellcheck disable=SC2034  # a sourced file: its variables are read by the scripts that source it
set -euo pipefail
umask 077
VBAL_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VBAL_STATE="$VBAL_ROOT/.secrets/vault"
# shellcheck disable=SC2034  # used by the scripts that source this file
BUILD_DIR="$VBAL_ROOT/.build"
export VAULT_CACERT="$VBAL_ROOT/vault-tls/ca-chain.pem"
unset VAULT_SKIP_VERIFY VAULT_NAMESPACE VAULT_TOKEN VAULT_TLS_SERVER_NAME
export VAULT_CONFIG_PATH="$VBAL_ROOT/scripts/vault-cli.hcl"

# shellcheck disable=SC2034
VBAL_SITES=$(jq -r '.sites[].id' "$VBAL_ROOT/config/sites.json" | tr '\n' ' ')
VBAL_SITES=${VBAL_SITES% }

# Effective config value: .env overrides config/defaults.conf.
vbal_conf() {
  local name=$1 v=""
  [ -f "$VBAL_ROOT/.env" ] && v=$(grep -E "^${name}=" "$VBAL_ROOT/.env" | tail -1 | cut -d= -f2- || true)
  [ -n "$v" ] || v=$(grep -E "^${name}=" "$VBAL_ROOT/config/defaults.conf" | tail -1 | cut -d= -f2- || true)
  printf '%s' "$v"
}

site_exists() { [[ " $VBAL_SITES " == *" $1 "* ]] || die "Unknown site '$1' (known: $VBAL_SITES)"; }

# The role a site has at bootstrap (config/sites.json): primary, performance, dr.
site_bootstrap_role() { jq -er --arg s "$1" '.sites[] | select(.id == $s) | .role' "$VBAL_ROOT/config/sites.json"; }

# site_nodes <site>: its Vault hostnames, space separated.
site_nodes() {
  jq -er --arg s "$1" '.sites[] | select(.id == $s) | [range(1; .nodes + 1) | "vault-\($s)-\(.)"] | join(" ")' \
    "$VBAL_ROOT/config/sites.json"
}

# site_of <host>: seal-ams -> ams, vault-ams-2 -> ams.
site_of() {
  case "$1" in
  seal-*) printf '%s' "${1#seal-}" ;;
  vault-*-*) local s=${1#vault-} && printf '%s' "${s%-*}" ;;
  *) die "Unknown Vault host: $1" ;;
  esac
}

# Container names keep one dash, after the prefix; the service's own dashes
# become underscores (vault-ams-1 -> vbal-vault_ams_1) so Podman tools show the
# whole name. Hostnames (DNS, TLS, retry_join) keep their dashes.
vault_container() { printf 'vbal-%s' "${1//-/_}"; }

# vault_port_of <host>: seal-ams -> VBAL_PORT_SEAL_AMS, vault-ams-1 -> VBAL_PORT_VAULT_AMS_1.
vault_port_of() {
  local name
  case "$1" in
  seal-*) name="VBAL_PORT_SEAL_$(tr '[:lower:]' '[:upper:]' <<<"${1#seal-}")" ;;
  vault-*-*) name="VBAL_PORT_$(tr '[:lower:]-' '[:upper:]_' <<<"$1")" ;;
  *) die "Unknown Vault host: $1" ;;
  esac
  local p
  p=$(vbal_conf "$name")
  [ -n "$p" ] || die "$name is not set in config/defaults.conf"
  printf '%s' "$p"
}

# Point VAULT_ADDR at one host's published port.
vault_node() {
  VAULT_ADDR="https://127.0.0.1:$(vault_port_of "$1")"
  export VAULT_ADDR
}

# `vault status` exits 2 when sealed; that is still a valid answer.
vault_json() {
  local code=0
  VAULT_CLIENT_TIMEOUT=${VAULT_CLIENT_TIMEOUT:-5s} vault status -format=json || code=$?
  [ "$code" -eq 0 ] || [ "$code" -eq 2 ]
}

# vault_site <site>: point VAULT_ADDR at the first node of the site that
# answers unsealed (standbys forward). Returns 1 when none does.
vault_site() {
  local n
  for n in $(site_nodes "$1"); do
    vault_node "$n"
    if vault_json 2>/dev/null | jq -e '.initialized and (.sealed | not)' >/dev/null 2>&1; then
      return 0
    fi
  done
  vault_node "vault-$1-1"
  return 1
}

# vault_active <site>: point VAULT_ADDR at the site's active node.
vault_active() {
  local n
  for n in $(site_nodes "$1"); do
    vault_node "$n"
    if curl -sf --max-time 5 --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/sys/leader" | jq -e '.is_self' >/dev/null 2>&1; then
      return 0
    fi
  done
  echo "No active node in site $1." >&2
  return 1
}

# replication_status <site>: sys/replication/status (unauthenticated) of the
# site's first unsealed node, as JSON .data; {} when unreachable.
replication_status() {
  vault_site "$1" >/dev/null 2>&1 || {
    echo '{}'
    return 0
  }
  curl -sf --max-time 5 --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/sys/replication/status" | jq -c '.data // {}' 2>/dev/null || echo '{}'
}

# fenced <site>: true when the front door fences that site (D11).
fenced() {
  local f="$BUILD_DIR/frontdoor/fenced.json"
  [ -s "$f" ] && jq -e --arg s "$1" 'index($s) != null' "$f" >/dev/null 2>&1
}

# vault_primary: set VBAL_PRIMARY to the site that is primary now and point
# VAULT_ADDR at it (call it directly, never in $(...): a subshell loses both).
# Vault decides: the reachable, unfenced site whose replication status says
# primary. Before replication is enabled, the bootstrap primary of
# config/sites.json. Fails when there is none or more than one (split brain).
VBAL_PRIMARY=""
vault_primary() {
  local s found=() st
  for s in $VBAL_SITES; do
    fenced "$s" && continue
    st=$(replication_status "$s")
    if jq -e '(.dr.mode == "primary") or (.performance.mode == "primary")' <<<"$st" >/dev/null 2>&1; then
      found+=("$s")
    fi
  done
  if [ "${#found[@]}" -eq 0 ]; then
    s=$(jq -r '.sites[] | select(.role == "primary") | .id' "$VBAL_ROOT/config/sites.json")
    st=$(replication_status "$s")
    if jq -e '(.dr.mode // "disabled") == "disabled" and (.performance.mode // "disabled") == "disabled"' <<<"$st" >/dev/null 2>&1 &&
      vault_site "$s" >/dev/null 2>&1; then
      VBAL_PRIMARY=$s
      return 0
    fi
    echo "No site reports itself primary (and the bootstrap primary $s is not a fresh cluster)." >&2
    return 1
  fi
  [ "${#found[@]}" -eq 1 ] || {
    echo "More than one unfenced site reports primary: ${found[*]}. Fence one: make fence SITE=<site>" >&2
    return 1
  }
  vault_site "${found[0]}" >/dev/null 2>&1 || true
  VBAL_PRIMARY=${found[0]}
}

# vault_wait reachable|unsealed|active [attempts]
vault_wait() {
  local mode=$1 max=${2:-60} attempt state
  for ((attempt = 0; attempt < max; attempt++)); do
    if state=$(vault_json 2>/dev/null); then
      case "$mode" in
      reachable) return 0 ;;
      unsealed) jq -e '.initialized and (.sealed | not)' <<<"$state" >/dev/null && return 0 ;;
      active) jq -e '.initialized and (.sealed | not)' <<<"$state" >/dev/null &&
        curl -sf --max-time 5 --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/sys/leader" | jq -e '.is_self' >/dev/null && return 0 ;;
      esac
    fi
    sleep 2
  done
  echo "Timed out waiting for $VAULT_ADDR ($mode)." >&2
  return 1
}

# Read one field from .secrets/vault/<cluster>-init.json (cluster: seal-ams, vault-ams, ...).
vault_init_field() {
  jq -er "$2" "$VBAL_STATE/$1-init.json"
}

# Export a scoped token (D7): tf-seal-<site>, ansible-seal-<site>,
# tf-platform, ansible-platform (and probe, during prompt 03 only).
vault_token() {
  local file="$VBAL_STATE/tokens/$1"
  [ -s "$file" ] || {
    echo "Scoped token '$1' not found at ${file#"$VBAL_ROOT"/}. Run make lab (phases seal-init and bootstrap mint them)." >&2
    return 1
  }
  VAULT_TOKEN=$(cat "$file")
  export VAULT_TOKEN
  # Periodic tokens live as long as they are used: renew on every use (best effort).
  vault token renew >/dev/null 2>&1 || true
}

# The first 8 hex characters of SHA-256: how this lab shows a secret.
fingerprint() {
  printf '%s' "$1" | shasum -a 256 | cut -c1-8
}

vbal_container_state() {
  podman container inspect "$1" --format '{{.State.Status}}' 2>/dev/null || echo "not created"
}

# `vault list` on an empty path prints [] *and* exits 2: always one JSON array.
vault_list_json() {
  local o
  o=$(vault list -format=json "$1" 2>/dev/null) || true
  jq -c 'if type == "array" then . else [] end' <<<"${o:-[]}" 2>/dev/null || echo '[]'
}

info() { printf '\033[32m%s\033[0m\n' "$*" >&2; }
die() {
  printf '\033[31m%s\033[0m\n' "$*" >&2
  exit 1
}

# phases [tool]: scripts/phases.txt without comments, "<tool> <name>" per line
# (or only the names of one tool). The only phase list (golden_ticket).
phases() {
  local want="${1:-}" tool name _rest
  while read -r tool name _rest; do
    [[ -z "$tool" || "$tool" == \#* ]] && continue
    [[ "$_rest" == *"# pending"* ]] && continue
    if [[ -z "$want" ]]; then printf '%s %s\n' "$tool" "$name"
    elif [[ "$tool" == "$want" ]]; then printf '%s\n' "$name"; fi
  done <"$VBAL_ROOT/scripts/phases.txt"
}
