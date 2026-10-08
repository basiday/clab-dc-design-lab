#!/bin/sh
# cl1-h3: leaf-3:swp3
# VRF-CL1 / vlan10 (low-latency): jumbo MTU 9000, VLAN 10 тегирован.
# DSCP -> skb priority -> 802.1p (CoS) + strict priority на NIC.
#   EF   (DSCP 46) -> prio 5 -> PCP 5 -> band 0  (latency-critical: RPC, heartbeat)
#   AF41 (DSCP 34) -> prio 4 -> PCP 4 -> band 1  (репликация)
#   BE   (DSCP 0)  -> prio 0 -> PCP 0 -> band 1
#   CS1  (DSCP 8)  -> prio 1 -> PCP 1 -> band 2  (bulk/scavenger)

set -e
ip link set eth1 mtu 9000 up
ip link add link eth1 name eth1.10 type vlan id 10 egress-qos-map 0:0 1:1 4:4 5:5 6:6 7:7
ip link set eth1.10 mtu 9000 up
ip addr add 10.10.10.14/24 dev eth1.10
ip route replace default via 10.10.10.1

tc qdisc add dev eth1.10 clsact
tc filter add dev eth1.10 egress prio 1 protocol ip flower ip_tos 0xb8/0xfc action skbedit priority 5
tc filter add dev eth1.10 egress prio 2 protocol ip flower ip_tos 0x88/0xfc action skbedit priority 4
tc filter add dev eth1.10 egress prio 3 protocol ip flower ip_tos 0x20/0xfc action skbedit priority 1
# priomap: индекс = skb->priority, значение = band (0 — наивысший)
tc qdisc replace dev eth1 root handle 1: prio bands 3 priomap 1 2 1 1 1 0 0 0 1 1 1 1 1 1 1 1
