#!/usr/bin/env bash
# Полный цикл с нуля: containerlab deploy -> ждём загрузку VM Cumulus -> заливаем конфиги -> check.sh
# (check.sh сам ждёт снятия protodown: EVPN-MH startup-delay и MLAG init-delay, по 180 с).
# Использование: scripts/up.sh [доп. флаги containerlab deploy]
#                CLAB_DOCKER=1 scripts/up.sh   — containerlab из контейнера, без sudo
set -euo pipefail
cd "$(dirname "$0")/.."
LAB=evpn
SWITCHES=(spine-1 spine-2 leaf-1 leaf-2 leaf-3 leaf-4)
BOOT_TIMEOUT=600
start=$SECONDS

# --reconfigure: всегда чистый старт. vrnetlab хранит диск VM в clab-evpn/<node>/config.
# Со старого диска VM не станет healthy: пароль уже сменён, а NVUE отключён deploy.sh,
# тогда как readiness-check vrnetlab ждёт активный nvued.
echo "==> containerlab deploy (--reconfigure)"
scripts/clab.sh deploy --reconfigure "$@"

echo "==> ждём загрузку VM (healthy, до $((BOOT_TIMEOUT / 60)) мин)"
deadline=$((SECONDS + BOOT_TIMEOUT))
for n in "${SWITCHES[@]}"; do
  until [[ $(docker inspect -f '{{.State.Health.Status}}' "clab-${LAB}-$n" 2>/dev/null) == healthy ]]; do
    if (( SECONDS > deadline )); then
      echo "!! $n не стал healthy. Лог загрузки: docker logs --tail 50 clab-${LAB}-$n" >&2
      exit 1
    fi
    sleep 5
  done
  echo "    $n: healthy"
done

echo "==> заливаем конфиги"
scripts/deploy.sh

echo "==> проверки"
rc=0; scripts/check.sh || rc=$?
printf '\n==> лаба поднята за %d мин %d с\n' $(((SECONDS - start) / 60)) $(((SECONDS - start) % 60))
exit "$rc"
