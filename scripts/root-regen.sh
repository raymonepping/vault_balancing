#!/usr/bin/env bash
# scripts/root-regen.sh [--revoke] <seal-<site>|primary>
#
# Only when the operator asks (D6). Runs `vault operator generate-root` with a
# one-time password and the saved unseal key (a seal Vault) or recovery key
# (the replicated cluster, on whichever site is primary now), and writes the
# root token to .secrets/vault/root-<cluster> (0600). It prints where the
# token is, never the token. --revoke revokes and deletes it.
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

revoke=false
if [ "${1:-}" = --revoke ]; then
  revoke=true
  shift
fi
cluster=${1:?Usage: root-regen.sh [--revoke] seal-<site>|primary}
case "$cluster" in
seal-*)
  site_exists "${cluster#seal-}"
  vault_node "$cluster"
  ;;
primary) vault_primary >/dev/null ;;
*) die "root-regen: unknown cluster $cluster (seal-<site>|primary)" ;;
esac
out="$VBAL_STATE/root-$cluster"

if [ "$revoke" = true ]; then
  [ -s "$out" ] || {
    echo "root-regen: no regenerated root token for $cluster"
    exit 0
  }
  VAULT_TOKEN=$(cat "$out") vault token revoke -self >/dev/null 2>&1 || true
  rm -f "$out"
  echo "root-regen: $cluster root token revoked and ${out#"$VBAL_ROOT"/} deleted"
  exit 0
fi

# Vault 2.x: generate-root needs a token as well as the key share
# (HCSEC-2026-08). The Ansible token of that cluster holds sys/generate-root/*.
[ ! -s "$out" ] || die "root-regen: ${out#"$VBAL_ROOT"/} already exists; make root-revoke CLUSTER=$cluster first"
if [[ "$cluster" == seal-* ]]; then
  vault_token "ansible-$cluster"
  key=$(vault_init_field "$cluster" '.unseal_keys_b64[0]')
else
  vault_token ansible-platform
  # shortcut: a secondary takes over the primary's recovery keys on activation,
  # so the replicated cluster's key is the bootstrap primary's; if a drill ever
  # re-keys, record which file holds the current key in STATE.md.
  key=$(vault_init_field "vault-$(node "$VBAL_ROOT/scripts/sites.js" primary)" '.recovery_keys_b64[0]')
fi
vault operator generate-root -cancel >/dev/null 2>&1 || true
otp=$(vault operator generate-root -generate-otp)
nonce=$(vault operator generate-root -init -otp="$otp" -format=json | jq -r '.nonce')
# The key share goes to the API in a JSON body on curl's stdin (printf is a
# builtin: no command line holds it), with the Ansible token as Vault 2.x needs.
encoded=$(printf '{"key":"%s","nonce":"%s"}' "$key" "$nonce" | curl -s --max-time 10 --cacert "$VAULT_CACERT" \
  -H "X-Vault-Token: $VAULT_TOKEN" -X PUT --data-binary @- "$VAULT_ADDR/v1/sys/generate-root/update" | jq -r '.encoded_token')
unset key
[ -n "$encoded" ] && [ "$encoded" != null ] || die "root-regen: generate-root did not complete"
token=$(vault operator generate-root -decode="$encoded" -otp="$otp")
unset otp encoded
: >"$out"
chmod 600 "$out"
printf '%s' "$token" >"$out"
VAULT_TOKEN=$token vault token lookup >/dev/null
unset token VAULT_TOKEN
echo "root-regen: $cluster root token written to ${out#"$VBAL_ROOT"/} (0600). Revoke it with make root-revoke CLUSTER=$cluster."
