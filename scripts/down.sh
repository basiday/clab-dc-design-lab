#!/usr/bin/env bash
# Остановить лабу и удалить контейнеры, линки и clab-evpn/ (диски VM).
# Использование: scripts/down.sh
#                CLAB_DOCKER=1 scripts/down.sh   — containerlab из контейнера, без sudo
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/clab.sh destroy --cleanup "$@"
