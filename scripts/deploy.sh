#!/usr/bin/env bash

set -euo pipefail
cd "$(dirname "$0")/.."

LAB=evpn
USER=cumulus
PASS='Clab123!'
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
SWITCHES=(spine-1 spine-2 leaf-1 leaf-2 leaf-3 leaf-4)
NODES=("$@"); [[ ${#NODES[@]} -eq 0 ]] && NODES=("${SWITCHES[@]}")

deploy_one() {
  local n=$1 host="clab-${LAB}-$1"
  sshpass -p "$PASS" scp "${SSH_OPTS[@]}" \
    configs/"$n"/interfaces configs/"$n"/frr.conf configs/"$n"/daemons configs/common/fabric-qos.sh \
    "$USER@$host:/tmp/"
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$USER@$host" "sudo -n bash -s" <<'REMOTE'
set -e
# Отключаем NVUE (иначе nv config apply перезатрёт наши файлы)
systemctl disable --now nvued.service nvued.socket >/dev/null 2>&1 || true
# Бэкап оригинала
[ -f /etc/network/interfaces.orig ] || cp /etc/network/interfaces /etc/network/interfaces.orig
[ -f /etc/frr/frr.conf.orig ]       || cp /etc/frr/frr.conf /etc/frr/frr.conf.orig 2>/dev/null || true

# Применяем. Повторный деплой — инкрементальный: ifreload + frr-reload без рестарта демонов
daemons_changed=1; cmp -s /tmp/daemons /etc/frr/daemons && daemons_changed=0
install -m 755 /tmp/fabric-qos.sh /usr/local/sbin/fabric-qos.sh
install -m 644 /tmp/interfaces /etc/network/interfaces
install -m 640 -o frr -g frr /tmp/daemons /etc/frr/daemons
install -m 640 -o frr -g frr /tmp/frr.conf /etc/frr/frr.conf
ifreload -a

if [ $daemons_changed = 1 ] || ! systemctl -q is-active frr; then
  systemctl restart frr
else
  /usr/lib/frr/frr-reload.py --reload /etc/frr/frr.conf >/dev/null
fi
REMOTE
  echo "==> ${n}: ok"
}

pids=()
for n in "${NODES[@]}"; do deploy_one "$n" & pids+=($!); done
rc=0; for p in "${pids[@]}"; do wait "$p" || rc=1; done
exit $rc
