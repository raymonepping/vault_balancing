#!/usr/bin/env bash
# scripts/app-build.sh [ticker|api|web ...]: build the app images (arm64). The
# build context is staged to $TMPDIR: macOS TCC can refuse Podman reads under
# ~/Documents, and xattrs break builds (gotcha 6).
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
export COPYFILE_DISABLE=1

targets=${*:-ticker api web}
prefix=$(vbal_conf VBAL_IMAGE_PREFIX)
tag=$(vbal_conf VBAL_IMAGE_TAG)

for t in $targets; do
  ctx=$(mktemp -d "${TMPDIR:-/tmp}/vbal-$t.XXXXXX")
  case "$t" in
  ticker)
    rsync -a --exclude node_modules --exclude test --exclude '._*' --exclude .DS_Store "$VBAL_ROOT/app/ticker/" "$ctx/"
    ;;
  api)
    rsync -a --exclude node_modules --exclude test --exclude '._*' --exclude .DS_Store "$VBAL_ROOT/api/" "$ctx/"
    ;;
  web)
    rsync -a --exclude node_modules --exclude dist --exclude test --exclude '._*' --exclude .DS_Store "$VBAL_ROOT/web/" "$ctx/"
    ;;
  *)
    echo "app-build: unknown target '$t'" >&2
    exit 64
    ;;
  esac
  [ -f "$ctx/Containerfile" ] || {
    echo "app-build: $t is not built yet (no Containerfile)" >&2
    rm -rf "$ctx"
    continue
  }
  xattr -rc "$ctx" 2>/dev/null || true
  # common.sh sets umask 077; the images run as non-root users that must read
  # these files.
  chmod -R a+rX "$ctx"
  echo "app-build: building $prefix/$t:$tag"
  podman build -q --format docker --platform linux/arm64 \
    --build-arg NODE_IMAGE="$(vbal_conf NODE_IMAGE)" \
    --build-arg NGINX_IMAGE="$(vbal_conf NGINX_IMAGE)" \
    -t "$prefix/$t:$tag" -f "$ctx/Containerfile" "$ctx" >/dev/null
  rm -rf "$ctx"
  arch=$(podman image inspect "$prefix/$t:$tag" --format '{{.Architecture}}')
  [ "$arch" = arm64 ] || {
    echo "app-build: $t is $arch, not arm64" >&2
    exit 1
  }
done
