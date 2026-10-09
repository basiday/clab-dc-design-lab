# EVPN/VXLAN DC fabric lab


* Leaf-Spine CLOS: **eBGP underlay** (/31, ECMP, BFD) и **iBGP EVPN overlay**, оба spine работают как route reflector.
* **EVPN/VXLAN**: L2 stretch, **symmetric IRB** (L3VNI), **anycast gateway**, маршруты Type-1/2/3/4/5.
* Два клиента, **VRF-CL1** и **VRF-CL2**, с **одинаковыми IP-подсетями**.
* **EVPN Multihoming all-active** на паре leaf-1/leaf-2 и **MLAG** на паре leaf-3/leaf-4.
* **Border** совмещён с leaf-1: eBGP в каждом VRF к внешнему маршрутизатору `bgw`, default уходит в фабрику как Type-5.
* Low-latency сегмент: **jumbo MTU**, **DSCP/CoS**, приоритетные очереди **Linux TC**.
* **OOB-управление** через VRF `mgmt`.
* Автоматизация: развёртывание с нуля, 80 проверок PASS/FAIL, graceful shutdown leaf с замером потерь.

Маршрутизацию делает FRR. NVUE отключён, конфигурация — чистые `frr.conf` и `/etc/network/interfaces` (ifupdown2).

## Быстрый старт

```bash
scripts/up.sh                  # deploy с нуля + конфиги + ожидание таймеров + проверки (~6 мин)
scripts/check.sh               # только проверки на работающей лабе
scripts/test-drain.sh leaf-1   # graceful shutdown leaf под нагрузкой, подсчёт потерь
scripts/down.sh                # снести лабу
```

Требования: Linux с KVM, Docker, ~16 ГБ RAM, `containerlab`, `sshpass`, `python3`, образ `vrnetlab/nvidia_cumulus-vx:5.12.1`. Как собрать образ, описано в [runbook](docs/runbook.md#1-требования). Без sudo можно запускать так: `CLAB_DOCKER=1 scripts/up.sh`, тогда containerlab берётся из официального контейнера.

## Требования → реализация → проверка

| Требование | Реализация | Проверка (`scripts/check.sh`) |
|---|---|---|
| Leaf-Spine, eBGP underlay, ECMP, /31 | spine AS 65100, leaf 65101–65104, /31 на линках, `maximum-paths 8` + `multipath-relax`, BFD 3×300 мс | сессии, BFD Up, 2 next-hop до VTEP и до anycast VTEP |
| Overlay iBGP EVPN, CLOS | AS 65000 через `local-as` на peer-group `OVERLAY`, оба spine — RR | EVPN-сессии к обоим RR |
| Type-2 / 3 / 5 (+ Type-1 / 4 для MH) | `advertise-all-vni`, `advertise ipv4 unicast` в VRF, RT `65000:<VNI>` | наличие маршрутов каждого типа |
| Symmetric IRB | L3VNI 4001 (VRF-CL1) и 4002 (VRF-CL2) | L3VNI Up, RMAC, host-маршрут `/32 via VTEP dev vlan4001` |
| Anycast Gateway | `address-virtual 00:00:5e:00:01:01 10.10.x.1` на всех leaf | ping между подсетями, MAC шлюза у хоста = anycast MAC |
| Border / Gateway | leaf-1 ↔ bgw, eBGP в каждом VRF, фильтры на вход и выход, default уходит как Type-5 | default на всех leaf через leaf-1, ping внешнего префикса из каждого VRF |
| ≥ 6 хостов | 8 хостов, по 4 на клиента | ping в обоих VRF |
| EVPN Multihoming all-active | cl1-h2 → leaf-1 + leaf-2, ESI type 3, DF по preference | peer по ES, ровно один DF, LACP в одном агрегаторе |
| MLAG | cl1-h4 → leaf-3 + leaf-4, clagd, anycast VTEP 10.255.2.34 | peer alive, bond dual-connected, backup через фабрику |
| 2 VRF с пересекающимися подсетями | VRF-CL1 и VRF-CL2: в обоих 10.10.10.0/24 и 10.10.20.0/24 | изоляция; один IP в двух VRF → MAC разных хостов |
| DSCP/CoS, Linux TC | хост: DSCP → priority → PCP, `prio`; фабрика: `prio` на 4 полосы + `flower` по DSCP, `tos inherit` в VXLAN | PCP 5 на входе в leaf, DSCP EF во внешнем заголовке на spine, счётчики EF-очереди |
| MTU 9000+ на транзитных линках | 9216 на фабрике и peerlink, 9000 в overlay и в jumbo-сегменте | MTU транзитных портов, ping 8972 B с DF через VXLAN |
| OOB-VRF | `eth0` в VRF `mgmt`, отдельная сеть 172.20.20.0/24, деплой и проверки идут только через неё | — |
| Graceful shutdown leaf | `scripts/drain-leaf.sh`: увод трафика → порты → BGP | `scripts/test-drain.sh`: 0–17 потерянных пакетов при 100 pps |

## Структура

```
├── README.md
├── topology.clab.yml            # containerlab: 6 VM Cumulus VX, bgw (FRR), 8 хостов
├── docs/
│   ├── architecture.md          # схема, узлы, линки, IP-план, VLAN/VNI/VRF, MH/MLAG, QoS, MTU
│   ├── design-decisions.md      # протоколы, ASN, RD/RT, DF election, ESI, MLAG vs EVPN-MH, QoS, OOB
│   ├── runbook.md               # развёртывание, проверки, диагностика, graceful shutdown
│   ├── topology.drawio          # диаграмма
│   └── notes.md                 # ссылки
├── configs/
│   ├── spine-{1,2}/             # interfaces, frr.conf, daemons
│   ├── leaf-{1..4}/             # interfaces, frr.conf, daemons
│   ├── common/fabric-qos.sh     # Linux TC на портах свитчей (post-up)
│   ├── bgw/                     # FRR + VRF внешнего маршрутизатора
│   └── cl{1,2}-h{1..4}/setup.sh # сеть хостов: bond / VLAN / IP / TC
└── scripts/
    ├── up.sh / down.sh          # поднять с нуля / снести
    ├── clab.sh                  # обёртка containerlab (sudo или контейнер)
    ├── deploy.sh                # залить конфиги на свитчи по OOB
    ├── check.sh                 # проверки PASS/FAIL
    ├── drain-leaf.sh            # graceful shutdown / возврат leaf
    └── test-drain.sh            # замер потерь при drain
```

## Известные ограничения

* Один border (leaf-1). Пока leaf-1 выведен в обслуживание, у клиентов нет выхода наружу.
* Single-homed хосты теряют связность, пока их leaf в обслуживании.
* Data plane Cumulus VX программный. QoS и задержки показывают логику, а не производительность.
* Подробнее: [design-decisions.md § 12](docs/design-decisions.md#12-известные-ограничения).
