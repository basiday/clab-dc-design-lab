#!/usr/bin/env bash
# Обёртка над containerlab.
# По умолчанию — локальный containerlab через sudo.
# CLAB_DOCKER=1 — официальный контейнер ghcr.io/srl-labs/clab (нужен только доступ к docker, без sudo).
# Использование: scripts/clab.sh deploy|destroy|inspect [доп. флаги]
set -euo pipefail
cd "$(dirname "$0")/.."
CLAB_VERSION=${CLAB_VERSION:-0.79.0}
cmd=$1; shift

if [[ ${CLAB_DOCKER:-0} != 1 ]]; then
  exec sudo containerlab "$cmd" -t topology.clab.yml "$@"
fi
exec docker run --rm -i --privileged --network host --pid host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/run/netns:/var/run/netns \
  -v /etc/hosts:/etc/hosts \
  -v /var/lib/docker/containers:/var/lib/docker/containers \
  -v "$PWD:$PWD" -w "$PWD" \
  ghcr.io/srl-labs/clab:"$CLAB_VERSION" containerlab "$cmd" -t topology.clab.yml "$@"
