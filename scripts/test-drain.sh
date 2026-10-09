#!/usr/bin/env bash
# Замер потерь при выводе leaf в обслуживание: ping 100 pps в обе стороны между multihomed-хостами
# cl1-h2 (EVPN-MH, leaf-1/2) <-> cl1-h4 (MLAG, leaf-3/4) во время drain и undrain.
# Использование: scripts/test-drain.sh <leaf-N> [hard]
#   hard — вместо graceful drain гасим порты и BGP сразу (для сравнения)
set -euo pipefail
cd "$(dirname "$0")/.."
leaf=${1:?usage: $0 <leaf-N> [hard]}; mode=${2:-drain}
[[ $mode == drain || $mode == hard ]] || { echo "usage: $0 <leaf-N> [hard]" >&2; exit 1; }
LIMIT=20   # допустимо пакетов (200 мс): окно LACP при возврате линка
hx() { docker exec "clab-evpn-$1" sh -c "$2"; }
declare -A PEER=([cl1-h2]=10.10.20.12 [cl1-h4]=10.10.20.11)

for h in "${!PEER[@]}"; do
  hx "$h" 'pkill ping' 2>/dev/null || true
  hx "$h" "ping -D -O -i 0.01 ${PEER[$h]} > /tmp/drain-ping.txt 2>&1 &"
done
sleep 3

scripts/drain-leaf.sh "$leaf" "$mode"
echo "--- leaf в обслуживании 10 с"; sleep 10
scripts/drain-leaf.sh "$leaf" undrain
sleep 5
for h in "${!PEER[@]}"; do hx "$h" 'pkill -INT ping' || echo "!! $h: ping уже не работал" >&2; done
sleep 1

echo; echo "=== $leaf, режим: $mode"
rc=0
for h in cl1-h2 cl1-h4; do
  line=$(hx "$h" 'grep "packets transmitted" /tmp/drain-ping.txt' || true)
  [[ -n $line ]] || { echo "$h: нет итога ping"; hx "$h" 'tail -5 /tmp/drain-ping.txt'; rc=1; continue; }
  tx=$(awk '{print $1}' <<<"$line"); rx=$(awk '{print $4}' <<<"$line"); lost=$((tx - rx))
  printf '%s -> %s: отправлено %s, потеряно %s (~%s мс)\n' "$h" "${PEER[$h]}" "$tx" "$lost" "$((lost * 10))"
  # окна потерь по времени хоста: подряд идущие "no answer" склеиваем в одно окно
  { hx "$h" "grep 'no answer' /tmp/drain-ping.txt" || true; } \
    | sed -E 's/^\[([0-9.]+)\].*icmp_seq=([0-9]+).*/\1 \2/' \
    | awk 'function t(x){return strftime("%T",int(x)) sprintf(".%03d",(x-int(x))*1000)}
           NR==1 || $2!=p+1 {if(NR>1) printf "    потери %s .. %s (%d пакетов)\n",t(s),t(l),c; s=$1; c=0}
           {l=$1; p=$2; c++}
           END {if(NR) printf "    потери %s .. %s (%d пакетов)\n",t(s),t(l),c}'
  (( lost <= LIMIT )) || rc=1
done
exit $rc
