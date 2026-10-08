#!/bin/sh


set -e
mk() {
  ip link add "$1" type vrf table "$2"
  ip link set "$1" up
  ip link add link eth1 name "eth1.$3" type vlan id "$3"
  ip link set "eth1.$3" master "$1" mtu 1500 up
  ip addr add "$4" dev "eth1.$3"
  ip link add "ext-$3" type dummy
  ip link set "ext-$3" master "$1" up
  ip addr add "$5" dev "ext-$3"
}
ip link set eth1 up
mk INET-CL1 101 101 172.16.1.1/31 1.1.1.1/32
mk INET-CL2 102 102 172.16.2.1/31 2.2.2.2/32
