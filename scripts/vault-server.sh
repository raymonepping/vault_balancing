#!/bin/sh
# scripts/vault-server.sh: entrypoint of every Vault server container.
# Renders /vault/config/config.hcl.tmpl into /tmp/config.hcl from VBAL_HOST,
# VBAL_SITE and VBAL_PEERS (one template for every node of every site, so
# there are no per-node HCL files to keep in step), then starts Vault.
set -eu

# Podman runs uid 100 without a usable HOME for the vault CLI's token helper.
export HOME=/tmp

: "${VBAL_HOST:?VBAL_HOST is not set}" "${VBAL_SITE:?VBAL_SITE is not set}"

# The Transit seal token is a file, never an environment variable in a compose
# file. A seal Vault has none (Shamir). It is read once, here: a replaced token
# is used from the next start on. Vault renews it while it runs.
if [ -e /run/secrets/transit-token ]; then
  [ -s /run/secrets/transit-token ] || {
    echo '[vault-server] the seal token file is empty; run make seal-tokens.' >&2
    exit 1
  }
  VAULT_TOKEN=$(cat /run/secrets/transit-token)
  export VAULT_TOKEN
fi

awk -v host="$VBAL_HOST" -v site="$VBAL_SITE" -v peers="${VBAL_PEERS:-}" '
  /@RETRY_JOIN@/ {
    n = split(peers, p, " ")
    for (i = 1; i <= n; i++)
      printf "  retry_join {\n    leader_api_addr     = \"https://%s:8200\"\n    leader_ca_cert_file = \"/vault/config/tls/ca-chain.pem\"\n  }\n", p[i]
    next
  }
  { gsub(/@HOST@/, host); gsub(/@SITE@/, site); print }
' /vault/config/config.hcl.tmpl >/tmp/config.hcl

mkdir -p /vault/file /vault/audit
exec vault server -config=/tmp/config.hcl
