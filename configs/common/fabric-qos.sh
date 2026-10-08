#!/bin/sh
# fabric-qos.sh <iface> — приоритизация на egress порта свитча средствами Linux TC.
# Вызывается из /etc/network/interfaces (post-up) для каждого swp; идемпотентен.
#
# Классификация по DSCP (trust DSCP). Для VXLAN это DSCP внешнего заголовка:
# на vxlan4094 стоит "tos inherit", поэтому внешний DSCP = DSCP хоста.
# Для тегированных кадров к хостам DSCP берётся из IP под тегом 802.1Q.
#
#   band 0 (1:1)  CS6/CS7  — network control (BGP, BFD)   strict priority
#   band 1 (1:2)  EF       — low-latency (кластер vlan10)
#   band 2 (1:3)  BE и всё остальное (default)
#   band 3 (1:4)  CS1      — scavenger / bulk
set -e
dev=$1
[ -n "$dev" ] || { echo "usage: $0 <iface>" >&2; exit 1; }

tc qdisc replace dev "$dev" root handle 1: prio bands 4 priomap 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
tc filter del dev "$dev" parent 1: 2>/dev/null || true

add() { # pref tos mask classid
  tc filter add dev "$dev" parent 1: pref "$1"          protocol ip    flower ip_tos "$2/$3" classid "$4"
  tc filter add dev "$dev" parent 1: pref "$((10 + $1))" protocol 802.1Q flower vlan_ethtype ip ip_tos "$2/$3" classid "$4"
}
add 1 0xc0 0xc0 1:1   # CS6, CS7
add 2 0xb8 0xfc 1:2   # EF  (DSCP 46)
add 3 0x20 0xfc 1:4   # CS1 (DSCP 8)
