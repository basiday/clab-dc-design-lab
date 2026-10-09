# Runbook

## 1. Требования

* Linux с KVM (`/dev/kvm`), Docker, ~16 ГБ RAM: шесть VM Cumulus по 2 ГБ плюс контейнеры.
* [containerlab](https://containerlab.dev/) 0.79+. Можно обойтись без локальной установки и без sudo: `CLAB_DOCKER=1` запускает официальный контейнер `ghcr.io/srl-labs/clab`.
* `sshpass`, `python3`.
* Образы:
  * `vrnetlab/nvidia_cumulus-vx:5.12.1` — собирается из qcow2-образа Cumulus VX 5.12.1 с помощью [vrnetlab](https://github.com/srl-labs/vrnetlab/tree/master/nvidia/cumulus-vx): положить qcow2 в `nvidia/cumulus-vx/` и выполнить `make`;
  * `quay.io/frrouting/frr:10.2.1` (bgw) и `nicolaka/netshoot:v0.13` (хосты) скачиваются автоматически.

Доступ к узлам (только через OOB):

```bash
ssh cumulus@clab-evpn-leaf-1        # свитч, пароль Clab123!
sudo vtysh                          # консоль FRR
docker exec -it clab-evpn-cl1-h1 bash
docker exec -it clab-evpn-bgw vtysh
```

## 2. Развёртывание

### Одной командой

```bash
scripts/up.sh                  # sudo containerlab
CLAB_DOCKER=1 scripts/up.sh    # containerlab из контейнера, без sudo
```

`up.sh` выполняет по шагам:

1. `containerlab deploy --reconfigure` — всегда чистый старт. Диск VM vrnetlab хранится в `clab-evpn/<узел>/`, а со старого диска VM не станет healthy.
2. Ждёт `healthy` у всех шести VM Cumulus, до 10 мин.
3. Запускает `scripts/deploy.sh` — заливает конфиги на свитчи.
4. Запускает `scripts/check.sh` — ждёт снятия protodown (до 180 с) и выполняет проверки.

Весь цикл занимает около 6 минут, из них ~3 минуты уходят на таймеры EVPN-MH и MLAG. Хосты и bgw настраиваются сами при старте (`exec` в `topology.clab.yml`).

### Вручную

```bash
sudo containerlab deploy -t topology.clab.yml --reconfigure
docker ps                       # дождаться (healthy) у spine/leaf
scripts/deploy.sh               # все свитчи; или scripts/deploy.sh leaf-1 leaf-2
scripts/check.sh
```

### Что делает deploy.sh

Для каждого свитча (параллельно, по SSH через OOB):

1. Отключает NVUE (`nvued`), чтобы он не перезаписал конфиги.
2. Один раз сохраняет оригиналы `*.orig`.
3. Устанавливает `interfaces`, `frr.conf`, `daemons` и `/usr/local/sbin/fabric-qos.sh`.
4. Выполняет `ifreload -a`.
5. Если `daemons` не изменился, выполняет `frr-reload.py` (инкрементально, без рестарта). Иначе рестартует FRR.
6. На MLAG-парах рестартует clagd, если изменились параметры `clagd-*`: clagd читает их только при старте, а `ifreload` их на работающем демоне не применяет. Рестарт clagd снова запускает `init-delay` (180 с).

### Изменение конфигурации

1. Правим `configs/<узел>/…`.
2. Выполняем `scripts/deploy.sh <узел>`.
3. Выполняем `scripts/check.sh`.

* Рестарт FRR (изменился `daemons` или первый деплой) снова запускает EVPN-MH `startup-delay`, и порты ES на 180 с уходят в protodown. `check.sh` это ждёт.
* Топологию (новые узлы и линки) можно поменять только пересозданием: vrnetlab создаёт NIC VM только при старте. После правки `topology.clab.yml` выполняем `scripts/up.sh`.
* Изменения `configs/<хост>/setup.sh` применяются при пересоздании лабы.

## 3. Остановка

```bash
scripts/down.sh                 # destroy --cleanup: контейнеры, линки и clab-evpn/ (диски VM)
```

## 4. Проверки

```bash
scripts/check.sh        # 82 проверки PASS/FAIL; код возврата = число FAIL
scripts/check.sh -v     # то же, с выводом команд у проваленных проверок
```

| Секция | Что проверяется |
|---|---|
| Готовность | на leaf нет портов в protodown (ждёт до 300 с) |
| Underlay | eBGP spine↔leaf, резервная eBGP через peerlink (leaf-3/4), BFD Up (`ptmctl -b`), ECMP до VTEP и anycast VTEP |
| Overlay | EVPN к обоим RR, маршруты Type-1/2/3/4/5 |
| Symmetric IRB | L3VNI 4001/4002 Up и привязаны к VRF, RMAC удалённых VTEP |
| Multihoming | ES-1: peer, ровно один DF, LACP одним агрегатором; MLAG: peer, dual, backup через фабрику |
| Data plane | L2 и L3 в обоих VRF, anycast GW MAC, host-маршрут через L3VNI |
| Border | eBGP leaf-1↔bgw, default на leaf-1 via bgw, на остальных via 10.255.1.1 (Type-5), ping 1.1.1.1 / 2.2.2.2 |
| Изоляция | CL1 не достаёт префикс CL2 и наоборот; один IP в двух VRF → MAC разных хостов |
| MTU | 9216 на транзите, ping 8972 B с DF через VXLAN |
| QoS | PCP 5 от хоста, `tos inherit`, DSCP EF во внешнем заголовке на spine, рост счётчика EF-очереди |

### Ручные проверки на свитче

```bash
# underlay
sudo vtysh -c 'show bgp ipv4 unicast summary'
sudo vtysh -c 'show ip route 10.255.2.34'              # ECMP к anycast VTEP
sudo ptmctl -b                                         # BFD
# overlay
sudo vtysh -c 'show bgp l2vpn evpn summary'
sudo vtysh -c 'show bgp l2vpn evpn route type macip'   # ead | macip | multicast | es | prefix
sudo vtysh -c 'show evpn vni'
sudo vtysh -c 'show evpn mac vni 10020'
sudo vtysh -c 'show evpn rmac vni all'
sudo vtysh -c 'show ip route vrf VRF-CL1'              # /32 и default via <VTEP> dev vlan4001 onlink
# multihoming
sudo vtysh -c 'show evpn es detail'                    # leaf-1/2: DF status, VTEPs
sudo vtysh -c 'show evpn'                              # startup-delay, protodown reasons
sudo clagctl -v                                        # leaf-3/4
# border (leaf-1)
sudo vtysh -c 'show bgp vrf VRF-CL1 summary'
# data plane
bridge fdb show br br_default | grep -v permanent
bridge vlan show
ip neigh show vrf VRF-CL1
# QoS
tc -s class show dev swp1                              # счётчики по полосам 1:1..1:4
ip -d link show vxlan4094 | grep tos
```

### Проверки с хостов

```bash
docker exec clab-evpn-cl1-h2 ping -c3 10.10.20.12                     # L2: MH -> MLAG
docker exec clab-evpn-cl1-h1 ping -c3 10.10.20.12                     # symmetric IRB
docker exec clab-evpn-cl1-h1 ping -c3 1.1.1.1                         # border, CL1
docker exec clab-evpn-cl2-h1 ping -c3 1.1.1.1                         # должен НЕ пройти (изоляция)
docker exec clab-evpn-cl1-h1 ping -c3 -M do -s 8972 10.10.10.14       # jumbo через VXLAN
docker exec clab-evpn-cl1-h1 ping -c50 -i 0.01 -Q 0xb8 10.10.10.14    # EF -> полоса 1:2 на фабрике
cat /proc/net/bonding/bond0                                            # внутри cl1-h2 / cl1-h4
```

## 5. Диагностика

| Симптом | Куда смотреть | Частые причины |
|---|---|---|
| После деплоя или рестарта хост на bond не отвечает | `ip -d link show swp4 \| grep protodown`, `show evpn`, `clagctl` | Идёт `startup-delay` / `init-delay` (180 с). Это норма, ждём |
| Нет eBGP spine↔leaf | `show bgp summary`, `ip -br addr`, `ptmctl -b` | Адрес /31 или `remote-as`, порт down, MTU |
| EVPN-сессии не поднимаются в обход прямого линка (например, через peerlink) | `show bgp neighbor 10.255.0.1` (строка «may be up to N hops away»), `nstat -az IpInHdrErrors` на транзитном узле | Нет `ttl-security hops` на `OVERLAY`: сессия уходит с TTL 1 и умирает на первом транзитном узле |
| Нет eBGP через peerlink (leaf-3/4) | `show bgp summary` (сосед `peerlink.4094`), `ip -6 addr show peerlink.4094` | Peerlink down, нет IPv6 link-local на `peerlink.4094` |
| Изменил `clagd-*`, но clagctl показывает старое | `clagctl`, `systemctl status clagd` | clagd не перезапущен (деплой не через `deploy.sh`) |
| Нет EVPN-сессий | `show bgp l2vpn evpn summary`, `ping -I 10.255.1.x 10.255.0.1` | Loopback не анонсирован (`PL-LOOPBACKS`), нет `update-source lo` |
| Нет Type-2/3 от соседа | `show evpn vni`, `show bgp l2vpn evpn route type multicast` | Нет `advertise-all-vni`, VNI не в `bridge-vlan-vni-map`, RT не совпадает |
| L2 работает, L3 между подсетями нет | `show evpn vni 4001`, `show evpn rmac vni all`, `show ip route vrf X` | Нет `vrf X / vni N`, нет SVI L3VNI или VLAN 400x в бридже, RT L3VNI |
| Нет ECMP до anycast VTEP | `show ip route 10.255.2.34` | Нет `multipath-relax` или `10.255.2.34/32` в prefix-list leaf-3/4 |
| MH: два DF или ни одного | `show evpn es detail` | Разный `es-sys-mac`/`es-id` на паре, ES в protodown, uplink'и down |
| MH: LACP хоста в двух агрегаторах | `/proc/net/bonding/bond0` (Aggregator ID) | Разный `es-sys-mac` у leaf-1/leaf-2 |
| MLAG: bond single-connected | `clagctl -v` (Conflicts, Proto-Down Reason) | Peerlink down, разные `clagd-sys-mac`, init-delay |
| MLAG: backup неактивен | `clagctl`, `ip route get 10.255.1.4 from 10.255.1.3` | Нет `RM-SET-SRC` (трафик идёт с /31, ответ не возвращается) |
| Нет выхода к 1.1.1.1 / 2.2.2.2 | leaf-1: `show bgp vrf VRF-CL1 summary`, `show ip route vrf VRF-CL1`; bgw: `vtysh -c 'show ip route vrf INET-CL1'` | Сессия к bgw, фильтры `RM-BGW-IN/OUT`, нет `advertise ipv4 unicast` в VRF |
| Jumbo не проходит | `ip link` по пути, `ping -M do -s 8972` | MTU на хосте, SVI, `vxlan4094` или uplink'е |
| EF не попадает в 1:2 | `tc -s class show dev swp1`, `tc filter show dev swp1` | Нет `post-up fabric-qos.sh`, нет `tos inherit`, хост не ставит DSCP |

Логи: `sudo journalctl -u frr`, `sudo journalctl -u clagd`, `sudo journalctl -u ptmd`. Для отладки FRR: `vtysh -c 'debug bgp updates'`, `debug zebra evpn mh es`.

## 6. Graceful shutdown одного leaf

Цель — вывести leaf в обслуживание так, чтобы хосты на двух leaf (cl1-h2 на EVPN-MH, cl1-h4 на MLAG) не потеряли трафик.

```bash
scripts/drain-leaf.sh leaf-3 drain       # вывести
scripts/drain-leaf.sh leaf-3 undrain     # вернуть
scripts/test-drain.sh leaf-3             # drain + undrain под ping 100 pps cl1-h2 <-> cl1-h4, подсчёт потерь
scripts/test-drain.sh leaf-3 hard        # для сравнения: порты и BGP сразу, без увода трафика
```

Изменения делаются в running-config FRR. `scripts/deploy.sh` (frr-reload) их сбрасывает, это и способ вернуть «забытый» drain.

### Вывод (drain)

Главный принцип: **сначала увести трафик фабрики с leaf, пока он ещё может доставить пакеты хосту, и только потом гасить порты и сессии.**

1. **Увести трафик фабрики.**
   * EVPN-MH leaf (leaf-1, leaf-2) — *cost-out ES*: route-map на overlay перестаёт анонсировать EAD (Type-1) этого leaf. Удалённые VTEP убирают его из aliasing для ES и отправляют трафик к хосту через соседа. Leaf при этом ещё принимает трафик от хоста и доставляет его.
     ```
     route-map RM-DRAIN-EVPN deny 10
      match evpn route-type ead
     route-map RM-DRAIN-EVPN permit 20
     router bgp <ASN>
      address-family l2vpn evpn
       neighbor OVERLAY route-map RM-DRAIN-EVPN out
     ```
   * MLAG leaf (leaf-3, leaf-4) — *AS_PATH prepend* в underlay: spine начинают отправлять трафик к anycast VTEP 10.255.2.34 через соседа.
     ```
     route-map RM-DRAIN permit 10
      set as-path prepend <ASN> <ASN> <ASN>
     router bgp <ASN>
      address-family ipv4 unicast
       neighbor UNDERLAY route-map RM-DRAIN out
     ```
2. **Погасить порты к хостам** (члены бриджа и `bond1`, peerlink не трогаем). Хост теряет carrier и переводит трафик на второй линк bond. На EVPN-MH отзывается Type-4, и DF переизбирается на соседа. На MLAG-соседе bond становится single-connected.
3. **BGP shutdown**: `neighbor OVERLAY shutdown`, `neighbor UNDERLAY shutdown`. Отзываются loopback и оставшиеся EVPN-маршруты. После этого leaf можно перезагружать или обновлять.

### Возврат (undrain) — строго в обратном порядке

1. `no neighbor UNDERLAY|OVERLAY shutdown` и ожидание EVPN-сессий и маршрутов. **Поднимать порты хостов раньше нельзя**: хост начнёт отправлять трафик в leaf без маршрутов (black-hole). После перезагрузки то же самое автоматически обеспечивают EVPN-MH `startup-delay` и MLAG `init-delay`.
2. Поднять порты к хостам. Они STP edge (`mstpctl-portadminedge`) и сразу переходят в forwarding.
3. Cost-in ES (снять `RM-DRAIN-EVPN`) или снять `RM-DRAIN`. Удалённые VTEP возвращают leaf в балансировку только теперь, когда LACP уже собран.

### Результаты (`test-drain.sh`, потеряно пакетов при 100 pps, cl1-h2→cl1-h4 / cl1-h4→cl1-h2)

| | Graceful | Hard (без увода трафика) |
|---|---|---|
| leaf-1 (EVPN-MH, border) | 0/0, 0/1, 0/0, 13/12, 13/0 | 16/15 |
| leaf-3 (MLAG) | 0/0, 17/1, 0/16, 0/7 | 0/22 |

* Сам увод трафика фабрики проходит без потерь. Оставшиеся окна по 50–170 мс приходятся на моменты, когда хост меняет состав bond. Особенно заметно на возврате линка: хост может начать слать в линк чуть раньше, чем сторона свитча готова принимать. Потери зависят от того, какой поток куда перехеширован, поэтому от прогона к прогону получается то 0, то десяток пакетов. Порог `test-drain.sh` — 200 мс.
* Порядок «carrier → admin down» важен. Если сначала погасить порт внутри VM, хост ещё ~200 мс шлёт в мёртвый порт: в vrnetlab это два разных события. Так было найдено тестом, и `drain-leaf.sh` сначала роняет carrier.
* Режим `hard` всё равно «вежливый»: `neighbor shutdown` отправляет соседям NOTIFICATION, и маршруты отзываются сразу. При настоящем отказе (питание) соседи узнают о нём только по BFD (~0,9 с), а хост — по LACP timeout (~3 с при `lacp_rate fast`). Сымитировать такой отказ можно через `docker pause clab-evpn-leaf-3`.

### Чего drain не спасает

* Single-homed хосты на выводимом leaf (например, cl1-h1 и cl2-h1 на leaf-1) теряют связность. Для них нужен multihoming.
* Drain leaf-1 отключает внешний выход (bgw) обоим клиентам: border один.

## 7. Отказ всех uplink'ов на MLAG-leaf

Проверка резервного underlay через peerlink: leaf-3 теряет оба uplink'а, но его хосты (в том числе single-homed cl1-h3 и cl2-h3) остаются в фабрике через leaf-4.

```bash
# обрыв (carrier снаружи VM + порт внутри)
docker exec clab-evpn-leaf-3 sh -c 'ip link set eth1 down; ip link set eth2 down'
ssh cumulus@clab-evpn-leaf-3 'sudo ip link set swp1 down; sudo ip link set swp2 down'
# через ~20 с
ssh cumulus@clab-evpn-leaf-3 "sudo vtysh -c 'show bgp summary'"            # spine Active, leaf-4(peerlink.4094) Established
ssh cumulus@clab-evpn-leaf-3 "sudo vtysh -c 'show bgp l2vpn evpn summary'" # EVPN к RR Established (через leaf-4)
docker exec clab-evpn-cl1-h3 ping -c3 10.10.20.11                         # проходит
docker exec clab-evpn-cl1-h3 ping -c3 1.1.1.1                             # проходит
# восстановление
ssh cumulus@clab-evpn-leaf-3 'sudo ip link set swp1 up; sudo ip link set swp2 up'
docker exec clab-evpn-leaf-3 sh -c 'ip link set eth1 up; ip link set eth2 up'
```

## 8. Особенности лабы

* **vrnetlab:**
  * `ip link set swpN down` в VM не роняет линк у соседа: снаружи остаётся живой veth;
  * NIC VM создаются только при старте, поэтому новые линки требуют пересоздания лабы;
  * диск VM сохраняется между запусками, поэтому используется `--reconfigure`.
* **Таймеры после старта FRR**: EVPN-MH `startup-delay` и MLAG `init-delay` по 180 с. Проверки раньше этого срока дают ложные FAIL.
* **Скрипты и `set -o pipefail`**: `cmd | tee | grep -q` может ложно провалиться. `grep -q` закрывает pipe на первом совпадении, `tee` получает SIGPIPE. В `check.sh` используется `grep … >/dev/null`.
