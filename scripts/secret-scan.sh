#!/usr/bin/env bash
# scripts/secret-scan.sh [paths...] (make secret-scan): look for secret
# material in Terraform state, .build/ (Ansible evidence and logs) and the
# last hour of every vbal- container's log. Two checks: every KNOWN value
# (read from .secrets/ into memory, compared, never printed) and
# secret-shaped PATTERNS. Prints only file names and labels.
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
declare -A values=()
add_file() { # <label> <file>
  [ -s "$2" ] && values["$1"]=$(tr -d '\n' <"$2")
  return 0
}
[ -s .secrets/vault/vault.hclic ] && values[license]=$(head -c 64 .secrets/vault/vault.hclic)
# A role-id is an identifier, not a credential (the secret-id is), and
# Terraform owns the AppRole roles, so their role_id sits in state by design.
for f in .secrets/vault/tokens/* .secrets/vault/seal/* .secrets/vault/dr-operation-token .secrets/approle/* \
  .secrets/identity/* .secrets/identity/users/* .secrets/identity/system/*; do
  [[ "$f" == */role-id ]] && continue
  [ -f "$f" ] && add_file "${f#.secrets/}" "$f"
done
for json in .secrets/vault/*-init.json; do
  [ -s "$json" ] || continue
  c=$(basename "$json" -init.json)
  i=0
  while IFS= read -r key; do
    values["$c-init-key$i"]=$key
    i=$((i + 1))
  done < <(jq -r '(.unseal_keys_b64 // []) + (.recovery_keys_b64 // []) + [.root_token // empty] | .[]' "$json")
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
  targets=("$BUILD_DIR")
  while IFS= read -r f; do targets+=("$f"); done < <(find .secrets/terraform -type f -name '*.tfstate*' 2>/dev/null)
  for c in $(podman ps -a --filter name=^vbal- --format '{{.Names}}'); do
    podman logs --since 1h "$c" >"$work/container-$c.log" 2>&1 || true
  done
  targets+=("$work")
fi

hits=0
for label in "${!values[@]}"; do
  value=${values[$label]}
  [ ${#value} -ge 8 ] || continue
  if files=$(grep -rlF -- "$value" "${targets[@]}" 2>/dev/null); then
    printf 'LEAK: %s found in %s\n' "$label" "$(sed "s#$work/##" <<<"$files" | paste -sd, -)" >&2
    hits=$((hits + 1))
  fi
done
# Vault service/batch/recovery tokens, the licence header, PEM private keys
# (header AND a base64 body: a library that only names the header is not a key).
patterns=('hv[sbr]\.[A-Za-z0-9_-]{20,}' '02MV4UU43BK5' '-----BEGIN [A-Z ]*PRIVATE KEY-----[[:space:]]+[A-Za-z0-9+/=]{40}')
for pattern in "${patterns[@]}"; do
  if files=$(grep -rlzE -- "$pattern" "${targets[@]}" 2>/dev/null); then
    printf 'LEAK: pattern %s found in %s\n' "${pattern:0:12}..." "$(sed "s#$work/##" <<<"$files" | paste -sd, -)" >&2
    hits=$((hits + 1))
  fi
done
mkdir -p "$BUILD_DIR/gates"
jq -n --arg result "$([ "$hits" -eq 0 ] && echo pass || echo fail)" --argjson values "${#values[@]}" \
  --argjson targets "${#targets[@]}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{gate: "secret-scan", result: $result, known_values: $values, targets: $targets, at: $at}' >"$BUILD_DIR/gates/secret-scan.json"
[ "$hits" -eq 0 ] || die "$hits secret finding(s)."
info "Secret scan clean: ${#values[@]} known values + ${#patterns[@]} patterns over ${#targets[@]} target(s)"
