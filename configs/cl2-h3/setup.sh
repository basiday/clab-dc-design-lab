#!/bin/sh
# cl2-h3: leaf-3:swp5

set -e
ip link set eth1 mtu 1500 up
ip addr add 10.10.10.13/24 dev eth1
ip route replace default via 10.10.10.1
