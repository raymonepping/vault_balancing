#!/usr/bin/env bash
# scripts/vault-cli.sh <vault args...> (make vault-cli CMD="..."): one vault
# command on the current primary with the ansible-platform token, which the
# CLI reads from the environment of this process only (never argv).
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
[ "$#" -gt 0 ] || die "Usage: make vault-cli CMD=\"namespace list\""
vault_primary || die "vault-cli: no primary"
vault_token ansible-platform
info "vault-cli: on $VBAL_PRIMARY ($VAULT_ADDR) as ansible-platform"
# CMD arrives as one string from make; split it into words on purpose.
# shellcheck disable=SC2068
vault $@
