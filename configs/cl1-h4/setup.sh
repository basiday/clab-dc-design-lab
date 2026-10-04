#!/bin/sh
# cl1-h4: leaf-3:swp4|leaf-4:swp4

set -e
ip link add bond0 type bond mode 802.3ad miimon 10 lacp_rate fast xmit_hash_policy layer3+4
for i in eth1 eth2; do ip link set $i down; ip link set $i master bond0; done
ip link set bond0 mtu 1500 up
ip addr add 10.10.20.12/24 dev bond0
ip route replace default via 10.10.20.1
