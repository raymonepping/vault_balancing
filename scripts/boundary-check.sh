#!/usr/bin/env bash
# scripts/boundary-check.sh (make boundary): prove the Terraform/Ansible
# boundary Vault enforces (golden_ticket's format). Each scoped token asks
# sys/capabilities-self what it may do on paths it must and must not touch.
# Seal rows run against each site's seal Vault; platform rows against the
# current primary (the replicated token store). Never prints a token.
# Rows: token|where|path|allow:cap or deny:cap. "where" is seal-<site> or primary.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

checks=()
for s in $VBAL_SITES; do
  checks+=(
    "tf-seal-$s|seal-$s|sys/mounts/transit|allow:create"
    "tf-seal-$s|seal-$s|auth/token/roles/autounseal|allow:update"
    "tf-seal-$s|seal-$s|sys/audit/file|allow:sudo"
    "tf-seal-$s|seal-$s|auth/token/create/autounseal|deny:update"
    "tf-seal-$s|seal-$s|sys/policies/acl/vbal-tf-seal|deny:update"
    "ansible-seal-$s|seal-$s|auth/token/create/autounseal|allow:update"
    "ansible-seal-$s|seal-$s|sys/generate-root/attempt|allow:update"
    "ansible-seal-$s|seal-$s|auth/token/roles/autounseal|deny:update"
    "ansible-seal-$s|seal-$s|sys/mounts/transit|deny:create"
    "ansible-seal-$s|seal-$s|sys/policies/acl/vbal-ansible-seal|deny:update"
  )
done
checks+=(
  # the replicated cluster (prompts 02 and 04)
  "tf-platform|primary|sys/namespaces/payments|allow:create"
  "tf-platform|primary|payments/sys/mounts/kv|allow:create"
  "tf-platform|primary|payments/sys/auth/approle|allow:sudo"
  "tf-platform|primary|sys/policies/acl/vbal-app-ticker|allow:update"
  "tf-platform|primary|sys/policies/acl/vbal-dr-operations|allow:update"
  "tf-platform|primary|auth/token/roles/vbal-dr-operations|allow:update"
  "tf-platform|primary|sys/audit/file|allow:sudo"
  "tf-platform|primary|sys/replication/performance/primary/paths-filter/fra|allow:update"
  "tf-platform|primary|sys/replication/dr/secondary/promote|deny:update"
  "tf-platform|primary|sys/replication/performance/primary/secondary-token|deny:update"
  "tf-platform|primary|auth/token/create/vbal-dr-operations|deny:update"
  "tf-platform|primary|payments/auth/approle/role/ticker/secret-id|deny:update"
  "tf-platform|primary|payments/kv/data/ticker/1|deny:read"
  "tf-platform|primary|sys/policies/acl/vbal-tf-platform|deny:update"
  "tf-platform|primary|sys/policies/acl/vbal-ansible-platform|deny:update"
  "ansible-platform|primary|sys/replication/performance/primary/secondary-token|allow:sudo"
  "ansible-platform|primary|sys/replication/dr/primary/demote|allow:sudo"
  "ansible-platform|primary|auth/token/create/vbal-dr-operations|allow:update"
  "ansible-platform|primary|payments/auth/approle/role/ticker/secret-id|allow:update"
  "ansible-platform|primary|sys/generate-root/attempt|allow:update"
  "ansible-platform|primary|sys/mounts/payments|deny:create"
  "ansible-platform|primary|payments/sys/mounts/kv|deny:create"
  "ansible-platform|primary|sys/policies/acl/vbal-app-ticker|deny:update"
  "ansible-platform|primary|payments/kv/data/ticker/1|deny:read"
  "ansible-platform|primary|sys/policies/acl/vbal-ansible-platform|deny:update"
)

primary_addr=""
fails=0
checked=0
skipped=0
for check in "${checks[@]}"; do
  IFS='|' read -r name where path expect <<<"$check"
  file="$VBAL_STATE/tokens/$name"
  if [ ! -s "$file" ]; then
    skipped=$((skipped + 1))
    continue
  fi
  if [ "$where" = primary ]; then
    [ -n "$primary_addr" ] || {
      vault_primary >/dev/null || die "boundary: no primary"
      primary_addr=$VAULT_ADDR
    }
    VAULT_ADDR=$primary_addr
  else
    vault_node "$where"
  fi
  caps=$(curl -sS --max-time 10 --cacert "$VAULT_CACERT" -H "X-Vault-Token: $(cat "$file")" \
    -X POST -d "{\"paths\":[\"$path\"]}" "$VAULT_ADDR/v1/sys/capabilities-self" |
    jq -r --arg p "$path" '(.data // .)[$p] // [] | join(",")')
  mode=${expect%%:*}
  cap=${expect#*:}
  has=no
  [[ ",$caps," == *",$cap,"* || ",$caps," == *",root,"* ]] && has=yes
  if { [ "$mode" = allow ] && [ "$has" = yes ]; } || { [ "$mode" = deny ] && [ "$has" = no ]; }; then
    printf '  \033[32mok\033[0m   %-17s %-5s %-6s %s\n' "$name" "$mode" "$cap" "$path"
  else
    printf '  \033[31mFAIL\033[0m %-17s %-5s %-6s %s (has: %s)\n' "$name" "$mode" "$cap" "$path" "${caps:-none}"
    fails=$((fails + 1))
  fi
  checked=$((checked + 1))
done
mkdir -p "$BUILD_DIR/gates"
jq -n --arg result "$([ "$fails" -eq 0 ] && echo pass || echo fail)" --argjson checked "$checked" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{gate: "boundary", result: $result, checks: $checked, at: $at}' >"$BUILD_DIR/gates/boundary.json"
[ "$fails" -eq 0 ] || die "$fails boundary check(s) failed."
[ "$checked" -gt 0 ] || die "no scoped token found: run make lab"
note=""
[ "$skipped" -eq 0 ] || note=", $skipped skipped: token not issued yet"
info "Token boundary holds ($checked checks$note)"
