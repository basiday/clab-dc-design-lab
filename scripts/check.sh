#!/usr/bin/env bash
# Проверки работоспособности фабрики. Каждая строка — PASS/FAIL.
# Использование: scripts/check.sh       — все проверки
#                scripts/check.sh -v    — с выводом команд при FAIL
# Код возврата: 0 — все PASS, иначе — число проваленных проверок.
set -uo pipefail
cd "$(dirname "$0")/.."
LAB=evpn; USER=cumulus; PASS='Clab123!'
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
VERBOSE=0; [[ ${1:-} == -v ]] && VERBOSE=1
LEAVES=(leaf-1 leaf-2 leaf-3 leaf-4); SPINES=(spine-1 spine-2)
READY_TIMEOUT=300   # EVPN-MH startup-delay и clagd init-delay — по 180 с после старта FRR
FAILED=0

sw()  { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "$USER@clab-${LAB}-$1" "sudo -n bash -c $(printf '%q' "$2")"; }
vt()  { sw "$1" "vtysh -c '$2'"; }
hx()  { docker exec "clab-${LAB}-$1" sh -c "$2"; }
py()  { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }

check() { # check "описание" команда...
  local name=$1; shift
  local out; out=$("$@" 2>&1); local rc=$?
  if [[ $rc -eq 0 ]]; then printf '  \e[32mPASS\e[0m  %s\n' "$name"
  else printf '  \e[31mFAIL\e[0m  %s\n' "$name"; FAILED=$((FAILED + 1))
       [[ $VERBOSE -eq 1 ]] && sed 's/^/          | /' <<<"$out"; fi
}
section() { printf '\n\e[1m== %s\e[0m\n' "$1"; }

# ---------- готовность ----------
# После старта FRR порты ES (frr) и bond/vxlan MLAG (clag) держатся в protodown.
# Проверки до снятия protodown дают ложные FAIL.
wait_ready() {
  local t=0 n busy
  while :; do
    busy=()
    for n in "${LEAVES[@]}"; do
      sw "$n" "ip -d link show" | grep 'protodown on' >/dev/null && busy+=("$n")
    done
    if [[ ${#busy[@]} -eq 0 ]]; then
      # protodown только что снят: даём EVPN разослать маршруты, LACP — договориться
      (( t > 0 )) && sleep 15
      printf '  фабрика готова (%d с)                    \n' "$t"; return 0
    fi
    (( t >= READY_TIMEOUT )) && { printf '  \e[33mprotodown не снят за %d с: %s\e[0m\n' "$t" "${busy[*]}"; return 1; }
    printf '  protodown: %s — ждём (%d/%d с)\r' "${busy[*]}" "$t" "$READY_TIMEOUT"
    sleep 10; t=$((t + 10))
  done
}

# ---------- helpers ----------
bgp_established() { # node vrf afi(ipv4Unicast|l2VpnEvpn) expected
  vt "$1" "show bgp vrf $2 summary json" | py "
p=d.get('$3',{}).get('peers',{}); up=[k for k,v in p.items() if v['state']=='Established']
print(up); sys.exit(0 if len(up)>=$4 else 1)"
}
bfd_up() { # node expected — BFD на Cumulus делает ptmd
  local n; n=$(sw "$1" "ptmctl -b" | tee /dev/stderr | awk '$3=="Up"' | wc -l)
  (( n >= $2 ))
}
ecmp() { # node prefix expected-nexthops
  vt "$1" "show ip route $2 json" | py "
n=[h for r in d['$2'] for h in r['nexthops'] if h.get('active')]; print(n); sys.exit(0 if len(n)>=$3 else 1)"
}
evpn_type() { # node type(ead|macip|multicast|es|prefix) min
  vt "$1" "show bgp l2vpn evpn route type $2 json" | py "
c=sum(1 for k,v in d.items() if isinstance(v,dict) for p in v.values() if isinstance(p,dict) and 'paths' in p)
print(c); sys.exit(0 if c>=$3 else 1)"
}
l3vni_up() { # node vni vrf
  vt "$1" "show evpn vni $2 json" | py "
print(d); sys.exit(0 if d.get('type')=='L3' and d.get('state')=='Up' and d.get('vrf')=='$3' else 1)"
}
rmacs() { # node vni min — RMAC удалённых VTEP (symmetric IRB)
  vt "$1" "show evpn rmac vni $2 json" | py "print(d); sys.exit(0 if d.get('numRmacs',0)>=$3 else 1)"
}
route_via() { # node vrf prefix nexthop-ip [iface] — лучший маршрут идёт через nexthop (и iface)
  vt "$1" "show ip route vrf $2 $3 json" | py "
r=[r for r in d.get('$3',[]) if r.get('selected')]; print(r)
ok=any(h.get('ip')=='$4' and ('${5:-}'=='' or h.get('interfaceName')=='${5:-}') for x in r for h in x['nexthops'])
sys.exit(0 if ok else 1)"
}
ping_ok()   { hx "$1" "ping -c 3 -i 0.2 -W 1 $2"; }
ping_fail() { ! hx "$1" "ping -c 2 -i 0.2 -W 1 $2"; }
gw_mac() { # host gw — ARP шлюза = общий anycast MAC
  hx "$1" "ping -c 1 -W 1 $2 >/dev/null; ip neigh show $2" | tee /dev/stderr | grep -i '00:00:5e:00:01:01' >/dev/null
}
neigh_mac() { # leaf vrf ip host-container host-iface — MAC в VRF = MAC нужного хоста
  local want; want=$(hx "$4" "cat /sys/class/net/$5/address")
  sw "$1" "ip neigh show vrf $2 $3" | tee /dev/stderr | grep -i "$want" >/dev/null
}

es_peer()   { vt leaf-1 'show evpn es detail' | tee /dev/stderr | grep '10.255.1.2' >/dev/null; }
es_one_df() { # в "show evpn es" флаг N = non-DF; DF должен быть ровно один
  local n=0 l
  for l in leaf-1 leaf-2; do vt "$l" 'show evpn es' | grep bond1 | tee /dev/stderr | awk '{print $2}' | grep -v N >/dev/null && n=$((n + 1)); done
  echo "DF count=$n"; [[ $n -eq 1 ]]
}
lacp_one_agg() { # host — оба слейва bond0 в одном агрегаторе (у пары общий system MAC)
  hx "$1" "cat /proc/net/bonding/bond0" | tee /dev/stderr \
    | awk '/^Slave Interface/{s=1} s && /Aggregator ID/{print $3; s=0}' | sort -u | wc -l | grep -x 1 >/dev/null
}
mlag_peer() { sw leaf-3 clagctl | tee /dev/stderr | grep 'peer is alive' >/dev/null && sw leaf-3 clagctl | grep 'Backup IP.*(active)' >/dev/null; }
mlag_dual() { sw leaf-3 'clagctl -v' | tee /dev/stderr | grep -E '^ *bond1 +bond1 +1 ' >/dev/null; }
mlag_backup_fabric() { # node me peer — backup-канал clagd живёт через фабрику, с loopback
  sw "$1" "ping -c2 -W1 -I $2 $3" >/dev/null || return 1
  sw "$1" "ip -4 route show $3" | tee /dev/stderr | grep "src $2" >/dev/null
}
mtu_is() { # node mtu ifaces...
  local n=$1 m=$2 i v bad=0; shift 2
  for i in "$@"; do v=$(sw "$n" "cat /sys/class/net/$i/mtu"); [[ $v == "$m" ]] || { echo "$n $i: $v"; bad=1; }; done
  return $bad
}
mtu_fabric() { # uplink/spine/peerlink — 9216
  local n r=0
  for n in "${SPINES[@]}"; do mtu_is "$n" 9216 swp1 swp2 swp3 swp4 || r=1; done
  for n in "${LEAVES[@]}"; do mtu_is "$n" 9216 swp1 swp2 || r=1; done
  for n in leaf-3 leaf-4; do mtu_is "$n" 9216 swp10 swp11 peerlink || r=1; done
  return $r
}

# --- QoS ---
tos_inherit() { local n; for n in "${LEAVES[@]}"; do sw "$n" 'ip -d link show vxlan4094' | grep 'tos inherit' >/dev/null || { echo "$n"; return 1; }; done; }
band_pkts() { # node "ifaces" classid — сумма пакетов в классе prio
  local n=$1 i v total=0
  for i in $2; do
    v=$(sw "$n" "tc -s class show dev $i" | awk -v c="$3" '$2=="prio" && $3==c {f=1} f && /Sent/ {print $4; exit}')
    total=$((total + ${v:-0}))
  done; echo "$total"
}
ef_spines() { echo $(( $(band_pkts spine-1 "swp3 swp4" 1:2) + $(band_pkts spine-2 "swp3 swp4" 1:2) )); }
qos_ef() { # EF cl1-h1 -> cl1-h3 попадает в band 1:2 на uplink leaf-1 и на spine (к leaf-3/4: anycast VTEP)
  local l0 s0 l1 s1
  l0=$(band_pkts leaf-1 "swp1 swp2" 1:2); s0=$(ef_spines)
  hx cl1-h1 "ping -c 50 -i 0.01 -Q 0xb8 -q 10.10.10.14" >/dev/null
  l1=$(band_pkts leaf-1 "swp1 swp2" 1:2); s1=$(ef_spines)
  echo "leaf-1 uplinks EF: +$((l1 - l0)), spines->leaf-3/4 EF: +$((s1 - s0))"
  (( l1 - l0 >= 50 && s1 - s0 >= 50 ))
}
capture_while_ping() { # node "tcpdump-args" — tcpdump на узле, пока cl1-h1 шлёт EF в vlan10
  local out; out=$(mktemp)
  sw "$1" "timeout 6 tcpdump -c 3 -nn $2" >"$out" 2>&1 &
  sleep 2; hx cl1-h1 "ping -c 20 -i 0.05 -Q 0xb8 -q 10.10.10.14" >/dev/null; wait
  cat "$out"; rm -f "$out"
}
host_pcp()   { capture_while_ping leaf-1 "-ei swp3 'vlan 10 and icmp'" | grep 'vlan 10, p 5' >/dev/null; }
outer_dscp() { # ECMP: пакет может уйти через любой spine — проверяем оба
  local sp ok=1
  for sp in "${SPINES[@]}"; do
    capture_while_ping "$sp" "-i any -v 'udp port 4789 and ip[1]&0xfc==0xb8'" | grep 'tos 0xb8' >/dev/null && ok=0
  done; return $ok
}

# ---------- checks ----------
section "Готовность (protodown после старта)"
wait_ready || FAILED=$((FAILED + 1))

section "Underlay: eBGP + BFD + ECMP"
for n in "${SPINES[@]}"; do check "$n: 4 eBGP-сессии к leaf" bgp_established "$n" default ipv4Unicast 4; done
for n in "${LEAVES[@]}"; do check "$n: eBGP к обоим spine"  bgp_established "$n" default ipv4Unicast 2; done
for n in leaf-3 leaf-4; do check "$n: резервный eBGP через peerlink (MLAG)" bgp_established "$n" default ipv4Unicast 3; done
for n in "${SPINES[@]}"; do check "$n: BFD Up к 4 leaf"     bfd_up "$n" 4; done
for n in "${LEAVES[@]}"; do check "$n: BFD Up к 2 spine"    bfd_up "$n" 2; done
check "leaf-1: ECMP до VTEP leaf-3 (10.255.1.3) через 2 spine" ecmp leaf-1 10.255.1.3/32 2
check "leaf-1: ECMP до anycast VTEP MLAG (10.255.2.34)"        ecmp leaf-1 10.255.2.34/32 2
check "spine-1: ECMP до anycast VTEP (leaf-3 + leaf-4)"        ecmp spine-1 10.255.2.34/32 2

section "Overlay: iBGP EVPN (spine = RR)"
for n in "${LEAVES[@]}"; do check "$n: iBGP EVPN к обоим RR" bgp_established "$n" default l2VpnEvpn 2; done
check "Type-1 (EAD) на leaf-3"       evpn_type leaf-3 ead 1
check "Type-2 (MAC/IP) на leaf-1"    evpn_type leaf-1 macip 4
check "Type-3 (IMET) на leaf-1"      evpn_type leaf-1 multicast 4
check "Type-4 (ES) на leaf-1"        evpn_type leaf-1 es 1
check "Type-5 (IP prefix) на leaf-3" evpn_type leaf-3 prefix 2

section "Symmetric IRB: L3VNI"
for n in "${LEAVES[@]}"; do
  check "$n: L3VNI 4001 -> VRF-CL1 Up" l3vni_up "$n" 4001 VRF-CL1
  check "$n: L3VNI 4002 -> VRF-CL2 Up" l3vni_up "$n" 4002 VRF-CL2
done
check "leaf-1: RMAC leaf-2 и пары MLAG (VNI 4001)" rmacs leaf-1 4001 2

section "Multihoming"
check "EVPN-MH: ES-1 на leaf-1 видит leaf-2 как peer"     es_peer
check "EVPN-MH: ровно один DF для ES-1"                   es_one_df
check "EVPN-MH: LACP cl1-h2 — оба линка в одном агрегаторе" lacp_one_agg cl1-h2
check "MLAG: peer alive, backup IP active"                mlag_peer
check "MLAG: bond1 dual-connected (clag-id 1)"            mlag_dual
check "MLAG: LACP cl1-h4 — оба линка в одном агрегаторе"  lacp_one_agg cl1-h4
check "MLAG: backup до соседа с loopback"                 mlag_backup_fabric leaf-4 10.255.1.4 10.255.1.3

section "Data plane: VRF-CL1"
check "L2 vlan10   cl1-h1 -> cl1-h3  10.10.10.14"  ping_ok cl1-h1 10.10.10.14
check "L2 vlan20   cl1-h2(MH) -> cl1-h4(MLAG)"     ping_ok cl1-h2 10.10.20.12
check "L3 IRB      cl1-h1 -> cl1-h4  10.10.20.12"  ping_ok cl1-h1 10.10.20.12
check "L3 IRB      cl1-h3 -> cl1-h2  10.10.20.11"  ping_ok cl1-h3 10.10.20.11
check "Anycast GW  cl1-h4: MAC 10.10.20.1 = 00:00:5e:00:01:01" gw_mac cl1-h4 10.10.20.1
check "leaf-1: 10.10.20.12/32 через L3VNI (vlan4001)" route_via leaf-1 VRF-CL1 10.10.20.12/32 10.255.2.34 vlan4001

section "Data plane: VRF-CL2 (те же подсети)"
check "L2 vlan110  cl2-h1 -> cl2-h3  10.10.10.13"  ping_ok cl2-h1 10.10.10.13
check "L2 vlan120  cl2-h2 -> cl2-h4  10.10.20.12"  ping_ok cl2-h2 10.10.20.12
check "L3 IRB      cl2-h1 -> cl2-h4  10.10.20.12"  ping_ok cl2-h1 10.10.20.12
check "L3 IRB      cl2-h3 -> cl2-h2  10.10.20.11"  ping_ok cl2-h3 10.10.20.11
check "Anycast GW  cl2-h2: MAC 10.10.20.1 = 00:00:5e:00:01:01" gw_mac cl2-h2 10.10.20.1

section "Border: leaf-1 <-> bgw"
check "leaf-1: eBGP к bgw в VRF-CL1" bgp_established leaf-1 VRF-CL1 ipv4Unicast 1
check "leaf-1: eBGP к bgw в VRF-CL2" bgp_established leaf-1 VRF-CL2 ipv4Unicast 1
check "leaf-1: default VRF-CL1 via bgw" route_via leaf-1 VRF-CL1 0.0.0.0/0 172.16.1.1 swp6.101
for n in leaf-2 leaf-3 leaf-4; do
  check "$n: default VRF-CL1 — Type-5 via leaf-1" route_via "$n" VRF-CL1 0.0.0.0/0 10.255.1.1 vlan4001
  check "$n: default VRF-CL2 — Type-5 via leaf-1" route_via "$n" VRF-CL2 0.0.0.0/0 10.255.1.1 vlan4002
done
for h in cl1-h1 cl1-h2 cl1-h3 cl1-h4; do check "$h -> 1.1.1.1 (INET-CL1)" ping_ok "$h" 1.1.1.1; done
for h in cl2-h1 cl2-h2 cl2-h3 cl2-h4; do check "$h -> 2.2.2.2 (INET-CL2)" ping_ok "$h" 2.2.2.2; done

section "Изоляция клиентов"
for h in cl1-h1 cl1-h4; do check "$h (CL1) НЕ достаёт 2.2.2.2" ping_fail "$h" 2.2.2.2; done
for h in cl2-h1 cl2-h4; do check "$h (CL2) НЕ достаёт 1.1.1.1" ping_fail "$h" 1.1.1.1; done
check "leaf-1: 10.10.20.12 в VRF-CL1 = MAC cl1-h4" neigh_mac leaf-1 VRF-CL1 10.10.20.12 cl1-h4 bond0
check "leaf-1: 10.10.20.12 в VRF-CL2 = MAC cl2-h4" neigh_mac leaf-1 VRF-CL2 10.10.20.12 cl2-h4 eth1

section "MTU"
check "Транзит (spine, uplink, peerlink) MTU 9216"             mtu_fabric
check "Jumbo vlan10: cl1-h1 -> cl1-h3 8972 B с DF через VXLAN" hx cl1-h1 "ping -c 3 -i 0.2 -W 1 -M do -s 8972 10.10.10.14"

section "QoS: DSCP / CoS / Linux TC"
check "Хост cl1-h1: EF -> PCP 5 в теге vlan10 (leaf-1 swp3)" host_pcp
check "VXLAN: tos inherit на vxlan4094 (все leaf)"           tos_inherit
check "Внешний заголовок VXLAN на spine несёт DSCP EF"       outer_dscp
check "EF в приоритетной очереди 1:2 (leaf-1 uplink и spine)" qos_ef

printf '\n'
if [[ $FAILED -eq 0 ]]; then printf '\e[32mВсе проверки пройдены\e[0m\n'; else printf '\e[31mПровалено: %d\e[0m\n' "$FAILED"; fi
exit "$FAILED"
