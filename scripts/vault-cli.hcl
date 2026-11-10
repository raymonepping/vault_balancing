# The lab's vault CLI config (scripts/common.sh sets VAULT_CONFIG_PATH): a
# token helper that returns nothing, so the operator's own ~/.vault-token is
# never sent to this lab. Every script sets VAULT_TOKEN itself.
token_helper = "/usr/bin/true"
