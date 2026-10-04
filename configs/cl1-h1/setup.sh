#!/bin/sh
# cl1-h1:leaf-1:swp3

set -e
ip link set eth1 mtu 9000 up
ip link add link eth1 name eth1.10 type vlan id 10
ip link set eth1.10 mtu 9000 up
ip addr add 10.10.10.13/24 dev eth1.10
ip route replace default via 10.10.10.1
