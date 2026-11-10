#!/bin/sh
# scripts/network.sh: create the shared network if it does not exist.
set -eu
podman network exists vbal-internal || podman network create --label io.vbal.project=vault_balancing vbal-internal >/dev/null
