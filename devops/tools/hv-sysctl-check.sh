#!/usr/bin/env bash
# hv-sysctl-check.sh - read-only sysctl/network audit for KVM (SolusVM) hypervisors
# Makes NO changes. Run as root:  bash hv-sysctl-check.sh | tee hv-report.txt

ID=0; NOK=0; NWARN=0; NFAIL=0
msg() {  # LEVEL TEXT
  ID=$((ID+1))
  printf '[%04d] %-4s %s\n' "$ID" "$1" "$2"
  case $1 in OK) NOK=$((NOK+1));; WARN) NWARN=$((NWARN+1));; FAIL) NFAIL=$((NFAIL+1));; esac
}
section() { ID=$((ID+1)); printf '\n[%04d] ==== %s ====\n' "$ID" "$1"; }
get() { sysctl -n "$1" 2>/dev/null; }

# check LEVEL KEY OP WANT "why it matters"
check() {
  local lvl=$1 key=$2 op=$3 want=$4 why=$5 have sym
  have=$(get "$key")
  if [ -z "$have" ]; then msg INFO "$key: not present (module not loaded / not applicable)"; return; fi
  have=${have%%[[:space:]]*}
  case $op in -ge) sym=">=";; -le) sym="<=";; -eq) sym="=";; -ne) sym="!=";; esac
  if [ "$have" "$op" "$want" ] 2>/dev/null; then
    msg OK "$key = $have"
  else
    msg "$lvl" "$key = $have (recommend $sym $want) - $why"
  fi
}

[ "$(id -u)" -ne 0 ] && msg WARN "Not running as root - some values/logs may be missing"
msg INFO "Host: $(hostname)  Kernel: $(uname -r)  Date: $(date -Is)"

section "ARP / neighbour tables (classic cause of random drops)"
check WARN net.ipv4.neigh.default.gc_thresh1 -ge 1024 "low ARP GC floor"
check WARN net.ipv4.neigh.default.gc_thresh2 -ge 4096 "soft ARP limit; overflow = intermittent unreachability"
check FAIL net.ipv4.neigh.default.gc_thresh3 -ge 8192 "hard ARP limit; 'neighbour table overflow' drops traffic"
check WARN net.ipv6.neigh.default.gc_thresh3 -ge 8192 "hard IPv6 ND limit"
t2=$(get net.ipv4.neigh.default.gc_thresh2); n4=$(ip -4 neigh show 2>/dev/null | wc -l)
n6=$(ip -6 neigh show 2>/dev/null | wc -l)
msg INFO "Current neighbour entries: IPv4=$n4 IPv6=$n6"
[ -n "$t2" ] && [ "$n4" -ge $((t2*8/10)) ] && msg FAIL "IPv4 neighbour count ($n4) is >=80% of gc_thresh2 ($t2)"

section "Bridge netfilter"
if [ -d /proc/sys/net/bridge ]; then
  for k in bridge-nf-call-iptables bridge-nf-call-ip6tables bridge-nf-call-arptables; do
    v=$(get net.bridge.$k)
    if [ "$v" = "1" ]; then
      msg WARN "net.bridge.$k = 1 - all bridged VM traffic hits iptables/conntrack; set 0 unless you filter VMs with iptables on the host (ebtables is unaffected)"
    else
      msg OK "net.bridge.$k = $v"
    fi
  done
else
  msg INFO "br_netfilter not loaded - bridged traffic bypasses iptables (good for performance)"
fi

section "Conntrack"
cmax=$(get net.netfilter.nf_conntrack_max); ccnt=$(get net.netfilter.nf_conntrack_count)
if [ -n "$cmax" ] && [ "$cmax" -gt 0 ]; then
  pct=$((ccnt*100/cmax))
  lvl=OK; [ $pct -ge 75 ] && lvl=WARN; [ $pct -ge 90 ] && lvl=FAIL
  msg $lvl "nf_conntrack usage: $ccnt / $cmax ($pct%) - full table = new connections silently dropped"
  check WARN net.netfilter.nf_conntrack_max -ge 262144 "small table for 10-20 VMs if VM traffic is tracked"
else
  msg INFO "nf_conntrack not loaded"
fi

section "Reverse path filtering / ARP behaviour"
all_rp=$(get net.ipv4.conf.all.rp_filter); strict=()
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do
  ifc=$(basename "$(dirname "$f")"); case $ifc in all|default|lo) continue;; esac
  v=$(cat "$f"); eff=$(( v > all_rp ? v : all_rp ))
  [ "$eff" -eq 1 ] && strict+=("$ifc")
done
if [ ${#strict[@]} -gt 0 ]; then
  msg WARN "Strict rp_filter (effective=1) on: ${strict[*]} - can drop asymmetric/multi-homed/routed traffic; 0 or 2 is typical"
else
  msg OK "No interfaces with strict rp_filter"
fi
msg INFO "ip_forward=$(get net.ipv4.ip_forward) (needed =1 only for routed setups)"
msg INFO "arp_ignore=$(get net.ipv4.conf.all.arp_ignore) arp_announce=$(get net.ipv4.conf.all.arp_announce) arp_filter=$(get net.ipv4.conf.all.arp_filter) proxy_arp=$(get net.ipv4.conf.all.proxy_arp)"

section "Packet processing / buffers"
check WARN net.core.netdev_max_backlog -ge 5000 "packets dropped under bursty load (see softnet drops below)"
check INFO net.core.netdev_budget -ge 600 "softirq may not drain queues fast enough"
check WARN net.core.rmem_max -ge 16777216 "small max socket receive buffer"
check WARN net.core.wmem_max -ge 16777216 "small max socket send buffer"

section "Memory (host stalls look like network blips)"
memkb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
swapused=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print t-f}' /proc/meminfo)
check WARN vm.swappiness -le 10 "host swapping qemu memory causes VM freezes"
[ "$swapused" -gt 0 ] && msg WARN "Host is currently using ${swapused} kB of swap"
mfk=$(get vm.min_free_kbytes)
if [ "$memkb" -gt 33554432 ] && [ "$mfk" -lt 262144 ]; then
  msg WARN "vm.min_free_kbytes = $mfk on $((memkb/1048576)) GB host - NIC drivers may hit atomic 'page allocation failure'"
else
  msg OK "vm.min_free_kbytes = $mfk"
fi
aionr=$(get fs.aio-nr); aiomax=$(get fs.aio-max-nr)
[ -n "$aiomax" ] && [ "$aionr" -ge $((aiomax*8/10)) ] && msg WARN "fs.aio-nr $aionr near aio-max-nr $aiomax (qemu aio=native)" || msg OK "fs.aio-nr $aionr / $aiomax"
check WARN fs.file-max -ge 1000000 "low system file handle limit"

section "Evidence: softirq drops"
drops=0; squeeze=0
while read -r _ d s _; do drops=$((drops+16#$d)); squeeze=$((squeeze+16#$s)); done < /proc/net/softnet_stat
[ $drops -gt 0 ] && msg WARN "softnet dropped=$drops (backlog full - raise netdev_max_backlog)" || msg OK "softnet dropped=0"
[ $squeeze -gt 0 ] && msg INFO "softnet time_squeeze=$squeeze (budget exhausted; small numbers are normal)"

section "Evidence: physical NIC counters"
for n in /sys/class/net/*; do
  [ -e "$n/device" ] || continue; i=$(basename "$n"); s="$n/statistics"
  line="rx_err=$(cat $s/rx_errors) rx_drop=$(cat $s/rx_dropped) rx_missed=$(cat $s/rx_missed_errors 2>/dev/null) tx_err=$(cat $s/tx_errors) carrier_changes=$(cat $n/carrier_changes 2>/dev/null)"
  msg INFO "$i ($(cat $n/operstate)) $line"
  [ "$(cat $n/carrier_changes 2>/dev/null || echo 0)" -gt 2 ] && msg WARN "$i has flapped link (carrier_changes) - check cable/switch port/SFP"
done

section "Evidence: kernel log (last 7 days if journald, else dmesg buffer)"
KLOG=$(journalctl -k --no-pager --since "-7d" 2>/dev/null)
[ -z "$KLOG" ] && KLOG=$(dmesg -T 2>/dev/null)

while IFS='~' read -r lvl pat label; do
  [ -z "$pat" ] && continue
  c=$(grep -Eic -- "$pat" <<<"$KLOG" 2>/dev/null); c=${c:-0}
  if [ "$c" -gt 0 ]; then
    msg "$lvl" "$label: $c hit(s). Last: $(grep -Ei -- "$pat" <<<"$KLOG" | tail -1 | cut -c1-160)"
  else
    msg OK "$label: none"
  fi
done <<'EOF'
FAIL~neighbour table overflow~ARP table overflow
FAIL~nf_conntrack: table full~Conntrack table full
FAIL~NETDEV WATCHDOG|tx timeout~NIC transmit timeout (driver/firmware/hardware)
WARN~link is down~NIC link down events
WARN~page allocation failure~Atomic memory allocation failures
FAIL~soft lockup|hard lockup|hung_task~CPU lockups / hung tasks (baremetal)
FAIL~machine check|mce:|EDAC~Hardware/memory errors (baremetal)
WARN~out of memory|oom-kill~OOM killer
WARN~bond.*(down|failure|disabled)~Bonding slave events
EOF

section "Summary"
msg INFO "OK=$NOK WARN=$NWARN FAIL=$NFAIL"
