#!/usr/bin/env bash
# scripts/app-up.sh [service...]: phase 11 (make app-up), and make web-up.
# Builds a missing image, starts the ticker's agent and the ticker (and the
# api and web once they exist), waits until each answers. This stack has no
# one-shot init container: the sink is a tmpfs volume created with its owner.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VBAL_ROOT"
prefix=$(vbal_conf VBAL_IMAGE_PREFIX)
tag=$(vbal_conf VBAL_IMAGE_TAG)
services=${*:-ticker}
for s in $services; do
  podman image exists "$prefix/$s:$tag" || ./scripts/app-build.sh "$s"
done
[ -s .secrets/approle/ticker/role-id ] || die "app-up: no ticker credential: run make replicate"
case " $services " in *" ticker "*) services="ticker-agent $services" ;; esac
# shellcheck disable=SC2086  # one word per service
./scripts/compose.sh app up -d $services >/dev/null
for s in $services; do
  [ "$s" = ticker-agent ] && continue
  c="vbal-$s"
  for _ in $(seq 1 60); do
    [ "$(podman container inspect "$c" --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] && break
    sleep 2
  done
  [ "$(podman container inspect "$c" --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] ||
    die "app-up: $c is not healthy (make app-logs)"
  echo "app-up: $c healthy"
done
