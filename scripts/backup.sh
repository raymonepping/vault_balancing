#!/usr/bin/env bash
# scripts/backup.sh (make backup): Raft snapshots of every seal Vault and of
# every live cluster, plus .secrets, into backups/<timestamp>/ (0700), named
# by site and role. Scoped tokens only. A DR secondary refuses a snapshot
# (Vault's answer is recorded, the site skipped); a performance secondary is
# read with a short batch token from the primary (gotcha 19).
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
dest="backups/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$dest"
chmod 700 backups "$dest"
: >"$dest/README.txt"
note() { echo "$*" | tee -a "$dest/README.txt"; }
for s in $VBAL_SITES; do
  vault_node "seal-$s"
  if vault_token "ansible-seal-$s" 2>/dev/null && vault operator raft snapshot save "$dest/seal-$s.snap" 2>"$dest/err"; then
    note "seal-$s: seal-$s.snap"
  else note "seal-$s: skipped ($(tr '\n' ' ' <"$dest/err"))"; fi
  unset VAULT_TOKEN
done
vault_primary || die "backup: no primary"
p=$VBAL_PRIMARY
vault_active "$p"
vault_token ansible-platform
vault operator raft snapshot save "$dest/$p-primary.snap"
note "$p (primary): $p-primary.snap"
batch=$(vault write -format=json -f auth/token/create/vbal-ansible-batch ttl=5m | jq -r .auth.client_token)
unset VAULT_TOKEN
for s in $VBAL_SITES; do
  [ "$s" = "$p" ] && continue
  rep=$(replication_status "$s")
  role=$(jq -r 'if .performance.mode == "secondary" then "performance-secondary" elif .dr.mode == "secondary" then "dr-secondary" else "unknown" end' <<<"$rep")
  vault_active "$s" 2>/dev/null || vault_node "vault-$s-1"
  if VAULT_TOKEN=$batch vault operator raft snapshot save "$dest/$s-$role.snap" 2>"$dest/err"; then
    note "$s ($role): $s-$role.snap"
  else note "$s ($role): skipped, Vault said: $(grep -v '^$' "$dest/err" | tail -1)"; fi
done
unset batch
rm -f "$dest/err"
tar -C "$VBAL_ROOT" -czf "$dest/secrets.tgz" .secrets
note "secrets.tgz: .secrets (init files, scoped tokens, seal tokens, state)"
du -sh "$dest" | awk '{print "backup: " $1}'
