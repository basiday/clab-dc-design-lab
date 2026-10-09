#!/usr/bin/env bash
# Graceful shutdown (maintenance) одного leaf без потери трафика для multihomed-хостов.
# Использование: scripts/drain-leaf.sh <leaf-N> drain|undrain|hard
#
# drain:
#   1. Уводим трафик фабрики ДО отключения портов, пока leaf ещё может доставить пакеты хосту:
#      EVPN-MH (leaf-1/2) — cost-out ES: route-map на overlay отзывает EAD (Type-1) этого leaf,
#                           удалённые VTEP убирают его из ECMP-группы ES (aliasing) и шлют трафик через соседа;
#      MLAG    (leaf-3/4) — AS_PATH prepend в underlay: spine уводят anycast VTEP 10.255.2.34 на соседа.
#   2. Гасим порты к хостам. Хост переводит исходящий трафик на второй линк bond (LACP).
#   3. Shutdown BGP (underlay + overlay): отзываются loopback и оставшиеся EVPN-маршруты.
# undrain — в обратном порядке: BGP (ждём маршруты) -> порты -> cost-in ES / снять prepend.
# hard    — для сравнения: порты и BGP гасятся сразу, без шага 1 (как внезапная поломка).
#
# Single-homed хосты на этом leaf теряют связность неизбежно.
# leaf-1 — ещё и border: в drain фабрика теряет выход к bgw (второго border нет).
# Изменения делаются в running-config FRR (без записи в frr.conf): scripts/deploy.sh их сбросит.
set -euo pipefail
cd "$(dirname "$0")/.."
LAB=evpn; USER=cumulus; PASS='Clab123!'
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

usage="usage: $0 <leaf-N> drain|undrain|hard"
leaf=${1:?$usage}; action=${2:?$usage}
[[ $leaf =~ ^leaf-([1-4])$ ]] || { echo "unknown leaf $leaf" >&2; exit 1; }
asn=$((65100 + BASH_REMATCH[1]))
sw()  { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$USER@clab-${LAB}-$leaf" "sudo -n bash -c $(printf '%q' "$1")"; }
vty() { local a=() c; for c in "$@"; do a+=(-c "'$c'"); done; sw "vtysh ${a[*]}"; }
log() { printf '%s  %s: %s\n' "$(date +%T.%3N)" "$leaf" "$*"; }

# vrnetlab: swpN в VM -> tap -> ethN контейнера -> veth -> хост. "ip link set swpN down" в VM
# не роняет линк у хоста (на железе хост теряет carrier сразу), поэтому гасим и ethN контейнера.
carrier() { local p; for p in $2; do docker exec "clab-${LAB}-$leaf" ip link set "eth${p#swp}" "$1"; done; }

is_mlag() { sw "grep -q clagd-peer-ip /etc/network/interfaces"; }

# порты к хостам = физические члены br_default и bond1 (peerlink и vxlan не трогаем)
host_ports() {
  sw "ip -o link show master br_default; ip -o link show master bond1" \
    | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E '^swp[0-9]+$' | sort -u | tr '\n' ' '
}

ports_down() {
  local ports; ports=$(host_ports)
  log "порты к хостам down: $ports"
  # сначала carrier: хост сразу видит обрыв и уводит трафик на второй линк bond.
  # Если сначала admin down в VM, хост ещё ~200 мс шлёт в мёртвый порт (было найдено тестом).
  carrier down "$ports"; sw "for p in $ports; do ip link set \$p down; done"
}

bgp_down() {
  log "BGP shutdown (underlay + overlay)"
  vty 'conf t' "router bgp $asn" 'neighbor OVERLAY shutdown' 'neighbor UNDERLAY shutdown'
}

evpn_ready() { # обе EVPN-сессии к RR подняты и маршруты получены
  sw "vtysh -c 'show bgp l2vpn evpn summary json'" | python3 -c '
import json,sys; p=json.load(sys.stdin).get("peers",{})
sys.exit(0 if sum(1 for v in p.values() if v["state"]=="Established" and v.get("pfxRcd",0)>0)>=2 else 1)'
}

case $action in
drain)
  if is_mlag; then
    log "1/3 MLAG: AS_PATH prepend в underlay — spine уводят anycast VTEP на соседа"
    vty 'conf t' 'route-map RM-DRAIN permit 10' "set as-path prepend $asn $asn $asn" 'exit' \
        "router bgp $asn" 'address-family ipv4 unicast' 'neighbor UNDERLAY route-map RM-DRAIN out'
  else
    log "1/3 EVPN-MH: cost-out ES — отзываем EAD (Type-1), трафик к ES идёт через соседа"
    vty 'conf t' 'route-map RM-DRAIN-EVPN deny 10' 'match evpn route-type ead' 'exit' \
        'route-map RM-DRAIN-EVPN permit 20' 'exit' \
        "router bgp $asn" 'address-family l2vpn evpn' 'neighbor OVERLAY route-map RM-DRAIN-EVPN out'
  fi
  sleep 3   # удалённые VTEP/spine пересчитывают пути
  log "2/3"; ports_down
  sleep 3   # хост убирает линк из bond (LACP)
  log "3/3"; bgp_down
  log "drained"
  ;;
hard)
  log "HARD: порты и BGP сразу, без увода трафика"
  ports_down; bgp_down
  log "down"
  ;;
undrain)
  log "1/3 BGP up"
  vty 'conf t' "router bgp $asn" 'no neighbor UNDERLAY shutdown' 'no neighbor OVERLAY shutdown'
  for _ in $(seq 1 60); do evpn_ready && break; sleep 1; done
  sleep 5   # дать EVPN и underlay сойтись до возврата трафика хостов
  ports=$(host_ports)
  log "2/3 порты к хостам up: $ports"
  sw "for p in $ports; do ip link set \$p up; done"; carrier up "$ports"
  sleep 5   # LACP собирает bond
  # после hard route-map'ов нет — "no ..." может вернуть ошибку, это нормально
  if is_mlag; then
    log "3/3 снимаем prepend"
    vty 'conf t' "router bgp $asn" 'address-family ipv4 unicast' 'no neighbor UNDERLAY route-map RM-DRAIN out' \
        'exit' 'exit' 'no route-map RM-DRAIN' >/dev/null 2>&1 || true
  else
    log "3/3 cost-in ES — снова анонсируем EAD (Type-1)"
    vty 'conf t' "router bgp $asn" 'address-family l2vpn evpn' 'no neighbor OVERLAY route-map RM-DRAIN-EVPN out' \
        'exit' 'exit' 'no route-map RM-DRAIN-EVPN' >/dev/null 2>&1 || true
  fi
  log "in service"
  ;;
*) echo "$usage" >&2; exit 1 ;;
esac
