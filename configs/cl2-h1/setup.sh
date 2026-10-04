#!/bin/sh
# cl2-h1: leaf-1:swp5

set -e
ip link set eth1 mtu 1500 up
ip addr add 10.10.10.14/24 dev eth1
ip route replace default via 10.10.10.1
