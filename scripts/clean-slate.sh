#!/usr/bin/env bash
# scripts/clean-slate.sh (make clean-slate CONFIRM=vbal): DESTRUCTIVE. Removes
# this lab's containers and volumes (vbal- only) and moves its Vault
# credentials, Terraform state and drill state aside to
# .secrets/legacy/<timestamp>/. Keeps the lab CA, the licence and the images.
# Back up first (make backup).
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"

answer=${CONFIRM:-}
if [ "$answer" != vbal ]; then
  printf 'This removes every vbal- container and volume (Vault data, audit logs, the ticker journal) and moves credentials aside. Type vbal: '
  read -r answer
fi
[ "$answer" = vbal ] || {
  echo "Aborted."
  exit 1
}
./scripts/runner.sh down >/dev/null 2>&1 || true
for stack in app identity frontdoor probe $VBAL_SITES; do
  ./scripts/compose.sh "$stack" down -v --remove-orphans >/dev/null 2>&1 || true
done
# Anything left with the prefix (a container started by hand, external volumes).
podman ps -a --filter name=^vbal- --format '{{.Names}}' | xargs -r podman rm -f >/dev/null
podman volume ls -q --filter name=^vbal- | xargs -r podman volume rm -f >/dev/null
podman network exists vbal-internal && podman network rm vbal-internal >/dev/null
legacy=".secrets/legacy/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$legacy"
for p in .secrets/vault/*-init.json .secrets/vault/seal .secrets/vault/tokens .secrets/vault/dr-operation-token \
  .secrets/vault/dr-operation-token.meta.json .secrets/vault/replication-ids.json .secrets/approle .secrets/terraform; do
  [ -e "$p" ] && mv "$p" "$legacy/"
done
mkdir -p "$legacy/build"
for p in .build/frontdoor .build/ansible-stats .build/gates .build/terraform .build/convergence.json .build/layers.json .build/seal-restart; do
  [ -e "$p" ] && mv "$p" "$legacy/build/"
done
echo "clean-slate: containers, volumes and network removed; credentials and state moved to $legacy"
echo "clean-slate: start again with make lab"
