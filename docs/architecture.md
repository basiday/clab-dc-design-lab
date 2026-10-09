# Архитектура

## Схема

Диаграмма: [topology.drawio](topology.drawio).


## Узлы

| Узел | Роль | Образ | ASN | Loopback / VTEP | OOB (eth0) |
|---|---|---|---|---|---|
| spine-1 | spine, EVPN RR | Cumulus VX 5.12.1 | 65100 | 10.255.0.1 | 172.20.20.11 |
| spine-2 | spine, EVPN RR | Cumulus VX 5.12.1 | 65100 | 10.255.0.2 | 172.20.20.12 |
| leaf-1 | leaf, EVPN-MH (ES-1), **border** | Cumulus VX 5.12.1 | 65101 | 10.255.1.1 | 172.20.20.21 |
| leaf-2 | leaf, EVPN-MH (ES-1) | Cumulus VX 5.12.1 | 65102 | 10.255.1.2 | 172.20.20.22 |
| leaf-3 | leaf, MLAG (primary) | Cumulus VX 5.12.1 | 65103 | 10.255.1.3, anycast 10.255.2.34 | 172.20.20.23 |
| leaf-4 | leaf, MLAG (secondary) | Cumulus VX 5.12.1 | 65104 | 10.255.1.4, anycast 10.255.2.34 | 172.20.20.24 |
| bgw | внешний маршрутизатор (upstream) | FRR 10.2.1 | 65200 | — | 172.20.20.31 |
| cl1-h1…h4, cl2-h1…h4 | серверы | netshoot | — | — | 172.20.20.100–103, 110–113 |

Overlay (iBGP EVPN) работает в общем AS **65000**: сессии peer-group `OVERLAY` используют `local-as 65000`.

## Линки

| A | B | Подсеть | MTU | Назначение |
|---|---|---|---|---|
| spine-1:swp1 | leaf-1:swp1 | 10.0.1.0/31 | 9216 | underlay |
| spine-1:swp2 | leaf-2:swp1 | 10.0.1.2/31 | 9216 | underlay |
| spine-1:swp3 | leaf-3:swp1 | 10.0.1.4/31 | 9216 | underlay |
| spine-1:swp4 | leaf-4:swp1 | 10.0.1.6/31 | 9216 | underlay |
| spine-2:swp1 | leaf-1:swp2 | 10.0.2.0/31 | 9216 | underlay |
| spine-2:swp2 | leaf-2:swp2 | 10.0.2.2/31 | 9216 | underlay |
| spine-2:swp3 | leaf-3:swp2 | 10.0.2.4/31 | 9216 | underlay |
| spine-2:swp4 | leaf-4:swp2 | 10.0.2.6/31 | 9216 | underlay |
| leaf-3:swp10, swp11 | leaf-4:swp10, swp11 | bond `peerlink`, link-local | 9216 | MLAG peerlink |
| leaf-1:swp6.101 | bgw:eth1.101 | 172.16.1.0/31 | 1500 | border, VRF-CL1 ↔ INET-CL1 |
| leaf-1:swp6.102 | bgw:eth1.102 | 172.16.2.0/31 | 1500 | border, VRF-CL2 ↔ INET-CL2 |
| leaf-1:swp3 | cl1-h1:eth1 | VLAN 10 (trunk) | 9000 | хост |
| leaf-1:swp4 + leaf-2:swp4 | cl1-h2:eth1, eth2 | bond1 / ES-1, VLAN 20 | 9000 / 1500 у хоста | хост EVPN-MH |
| leaf-1:swp5 | cl2-h1:eth1 | VLAN 110 (access) | 1500 у хоста | хост |
| leaf-2:swp5 | cl2-h2:eth1 | VLAN 120 (access) | 1500 у хоста | хост |
| leaf-3:swp3 | cl1-h3:eth1 | VLAN 10 (trunk) | 9000 | хост |
| leaf-3:swp4 + leaf-4:swp4 | cl1-h4:eth1, eth2 | bond1 / clag-id 1, VLAN 20 | 9000 / 1500 у хоста | хост MLAG |
| leaf-3:swp5 | cl2-h3:eth1 | VLAN 110 (access) | 1500 у хоста | хост |
| leaf-4:swp5 | cl2-h4:eth1 | VLAN 120 (access) | 1500 у хоста | хост |

Порты свитчей к хостам стоят на MTU 9000 (L2 «на максимум»). Реальный MTU сегмента задают SVI и хосты, см. [MTU](#mtu).

## План IP-адресации

| Префикс | Назначение |
|---|---|
| 10.255.0.0/24 | loopback spine (router-id) |
| 10.255.1.0/24 | loopback leaf (router-id, VTEP) |
| 10.255.2.34/32 | anycast VTEP пары MLAG leaf-3/leaf-4 |
| 10.0.1.0/24 | p2p /31 spine-1 ↔ leaf |
| 10.0.2.0/24 | p2p /31 spine-2 ↔ leaf |
| 172.16.1.0/31, 172.16.2.0/31 | p2p border leaf-1 ↔ bgw (по одной на VRF) |
| 172.20.20.0/24 | OOB management (docker-сеть `clab-oob`) |
| 10.10.10.0/24, 10.10.20.0/24 | подсети клиентов, **одинаковые в VRF-CL1 и VRF-CL2** |
| 1.1.1.1/32 | «внешний» префикс CL1 на bgw (VRF INET-CL1) |
| 2.2.2.2/32 | «внешний» префикс CL2 на bgw (VRF INET-CL2) |

В underlay анонсируются только loopback'и (`redistribute connected` с route-map `PL-LOOPBACKS`). Сети /31 в BGP не попадают, поэтому собственный трафик свитча идёт с адреса loopback (`ip protocol bgp route-map RM-SET-SRC`).

Адреса в подсетях клиентов:

| Адрес | Кто |
|---|---|
| .1 | anycast gateway, одинаковый на всех leaf (MAC `00:00:5e:00:01:01`) |
| .251 / .252 / .253 / .254 | собственный адрес SVI на leaf-1 / 2 / 3 / 4 |
| .11 – .14 | хосты |

## VLAN / VNI / VRF

| VLAN | VNI | Тип | VRF | Подсеть | Шлюз | Хосты | Назначение |
|---|---|---|---|---|---|---|---|
| 10 | 10010 | L2VNI | VRF-CL1 | 10.10.10.0/24 | 10.10.10.1 | cl1-h1 (.13), cl1-h3 (.14) | low-latency кластер: jumbo, QoS, VLAN тегирован |
| 20 | 10020 | L2VNI | VRF-CL1 | 10.10.20.0/24 | 10.10.20.1 | cl1-h2 (.11, MH), cl1-h4 (.12, MLAG) | серверы на двух leaf |
| 110 | 10110 | L2VNI | VRF-CL2 | 10.10.10.0/24 | 10.10.10.1 | cl2-h1 (.14), cl2-h3 (.13) | web |
| 120 | 10120 | L2VNI | VRF-CL2 | 10.10.20.0/24 | 10.10.20.1 | cl2-h2 (.11), cl2-h4 (.12) | web |
| 4001 | 4001 | L3VNI | VRF-CL1 | — | — | — | symmetric IRB, Type-5 |
| 4002 | 4002 | L3VNI | VRF-CL2 | — | — | — | symmetric IRB, Type-5 |

* Одно VXLAN-устройство на все VNI: `vxlan4094` (single VXLAN device, `bridge-vlan-vni-map`).
* Route Target: `65000:<VNI>`, задан явно. RD автоматический: `<router-id>:<index>`.
* VLAN 4001 и 4002 существуют только внутри `br_default`, ни на одном порту их нет. Они нужны, чтобы привязать VNI к VRF через SVI `vlan4001`/`vlan4002`. MAC этих SVI служит Router MAC (RMAC).
* Пересечение адресов намеренное: 10.10.10.13 — это cl1-h1 в VRF-CL1 и cl2-h3 в VRF-CL2.
* VRF внешнего маршрутизатора bgw: `INET-CL1` (table 101, VLAN 101) и `INET-CL2` (table 102, VLAN 102).

## Multihoming

| | EVPN-MH (leaf-1 + leaf-2) | MLAG (leaf-3 + leaf-4) |
|---|---|---|
| Хост | cl1-h2, bond0 802.3ad, `lacp_rate fast` | cl1-h4, bond0 802.3ad, `lacp_rate fast` |
| Порт свитча | `bond1` (swp4) | `bond1` (swp4), `clag-id 1` |
| Идентификатор | ESI `03:44:38:39:ff:00:01:00:00:01` (type 3: `es-sys-mac 44:38:39:ff:00:01` + `es-id 1`) | `clagd-sys-mac 44:38:39:ff:01:34` |
| LACP system ID | `es-sys-mac`, общий у пары | `clagd-sys-mac`, общий у пары |
| VTEP | у каждого leaf свой (10.255.1.1, 10.255.1.2) | общий anycast 10.255.2.34 |
| Связь между leaf | только через фабрику (Type-1/4) | peerlink (swp10+swp11) + backup через фабрику (loopback соседа) |
| DF / роль | DF по preference: leaf-1 50000 (**DF**), leaf-2 10000 | priority: leaf-3 1000 (**primary**), leaf-4 2000 |
| Uplink tracking | `evpn mh uplink` на swp1/swp2 | clagd |
| Старт | `startup-delay` 180 с (ES в protodown) | `init-delay` 180 с (bond и vxlan в protodown) |
| L3VNI SVI | MAC SVI = RMAC leaf | `hwaddress 44:38:39:ff:01:34` (= clagd-sys-mac): у пары один RMAC |

## Border

* leaf-1 подключён к bgw линком swp6. На каждый VRF свой сабинтерфейс (dot1q 101 и 102) и своя eBGP-сессия: AS 65101 ↔ AS 65200.
* Политика на leaf-1:
  * `RM-BGW-IN` — от bgw принимаются только `0.0.0.0/0`, `1.1.1.0/24 le 32` и `2.2.2.0/24 le 32`;
  * `RM-BGW-OUT` — наружу уходят только /24 клиентов (`10.10.0.0/16 ge 24 le 24`).
* bgw отдаёт default (`default-originate`) и свой префикс. leaf-1 экспортирует их в EVPN как Type-5 (`advertise ipv4 unicast` в VRF). На остальных leaf получается `0.0.0.0/0 via 10.255.1.1 dev vlan400x onlink`.

## QoS

Low-latency сегмент — VLAN 10 (cl1-h1, cl1-h3).

| Класс | DSCP | Хост: skb prio → PCP | Хост: полоса `prio` | Свитч: полоса `prio` |
|---|---|---|---|---|
| Network control (BGP, BFD) | CS6 / CS7 | — | — | 1:1 (наивысшая) |
| Low-latency (RPC, heartbeat) | EF (46) | 5 → 5 | 0 | 1:2 |
| Репликация | AF41 (34) | 4 → 4 | 1 | 1:3 |
| Best effort | 0 | 0 → 0 | 1 | 1:3 |
| Scavenger / bulk | CS1 (8) | 1 → 1 | 2 | 1:4 |

* Хост: `clsact` на `eth1.10` переводит DSCP в skb priority, `egress-qos-map` переводит priority в PCP, на `eth1` стоит `prio` на 3 полосы.
* Свитч: [configs/common/fabric-qos.sh](../configs/common/fabric-qos.sh) через `post-up` на каждом swp ставит `prio` на 4 полосы и фильтры `flower` по DSCP для IP и для 802.1Q.
* VXLAN: `tos inherit` на `vxlan4094`, DSCP внутреннего пакета копируется во внешний заголовок. Spine классифицирует VXLAN-трафик по внешнему DSCP.

## MTU

| Где | MTU |
|---|---|
| Underlay (spine ↔ leaf), peerlink, border swp6 | 9216 |
| `vxlan4094`, `br_default`, порты к хостам, L3VNI SVI (`vlan4001/4002`) | 9000 |
| VLAN 10 (SVI `vlan10`, хосты cl1-h1/cl1-h3) | 9000 |
| VLAN 20, 110, 120 (SVI и хосты), сабинтерфейсы border | 1500 |

Запас 9216 − 9000 = 216 байт перекрывает 50 байт заголовков VXLAN.

## OOB

* У каждого узла `eth0` подключён к docker-сети `clab-oob` (172.20.20.0/24).
* На свитчах `eth0` лежит в VRF `mgmt` (table 1001): трафик управления не видит таблиц фабрики и клиентов.
* `deploy.sh`, `check.sh` и `drain-leaf.sh` работают с узлами только через OOB: SSH на `clab-evpn-<узел>` и `docker exec` для хостов.
