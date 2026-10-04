#!/bin/sh
# cl2-h2: leaf-2:swp5

set -e
ip link set eth1 mtu 1500 up
ip addr add 10.10.20.11/24 dev eth1
ip route replace default via 10.10.20.1
