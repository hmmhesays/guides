#!/usr/bin/env bash
# freeswitch-tuning-audit.sh - read-only audit of kernel/OS tunings for a FreeSWITCH server
#
# Compares current kernel, sysctl and NIC settings to typical recommendations for a busy
# FreeSWITCH media server (SIP + RTP over UDP, high packet rates, many threads).
# Kernel and NIC only - it does not read FreeSWITCH's config or inspect the process.
#
# Makes NO changes. Takes ~5 seconds (one live sample of drop counters and CPU steal).
# Prints a suggested sysctl.d file, suggested NIC (ethtool) settings and other notes at the end.
#
# Usage (as root):  bash freeswitch-tuning-audit.sh | tee fs-tuning-report.txt
# Optional:  SAMPLE=5  seconds for the live sample (0 to skip)

SAMPLE=${SAMPLE:-5}
ID=0; NOK=0; NWARN=0; NFAIL=0; SUGGEST=(); NOTES=()

msg() {  # LEVEL TEXT
  ID=$((ID+1)); printf '[%04d] %-4s %s\n' "$ID" "$1" "$2"
  case $1 in OK) NOK=$((NOK+1));; WARN) NWARN=$((NWARN+1));; FAIL) NFAIL=$((NFAIL+1));; esac
}
section() { ID=$((ID+1)); printf '\n[%04d] ==== %s ====\n' "$ID" "$1"; }
get()   { sysctl -n "$1" 2>/dev/null; }
rd()    { cat "$1" 2>/dev/null; }
note()  { NOTES+=("$1"); }
has()   { command -v "$1" >/dev/null 2>&1; }
isnum() { [[ $1 =~ ^[0-9]+$ ]]; }
sel()   { grep -o '\[[^]]*\]' <<<"$1" | tr -d '[]'; }   # selected value from "a [b] c"
suggest() { SUGGEST+=("# [$(printf '%04d' "$ID")] $1" "$2"); }   # "reason" "key = value"
# Suggested NIC changes, keyed by "iface kind" so a stronger recommendation replaces a weaker one
declare -A NICVAL NICWHY
nicfix() {  # IFACE KIND VALUE "reason"   KIND: rxring | queues | hash | txring  (rings/queues keep the larger value)
  local k="$1 $2" id; id=$(printf '%04d' "$ID")
  if [ "$2" = rxring ] || [ "$2" = txring ] || [ "$2" = queues ]; then
    isnum "${NICVAL[$k]}" && [ "${NICVAL[$k]}" -ge "$3" ] && return
  fi
  NICVAL[$k]=$3; NICWHY[$k]="[$id] $4"
}

# tune LEVEL KEY OP WANT FIELD "reason"
#   OP: ge | le | eq     FIELD: whitespace field to compare for multi-value keys (1 = first)
tune() {
  local lvl=$1 key=$2 op=$3 want=$4 field=$5 why=$6 raw have ok=0 sym new
  raw=$(get "$key")
  if [ -z "$raw" ]; then msg INFO "$key: not present (module not loaded / not applicable)"; return; fi
  raw=$(tr -s '[:space:]' ' ' <<<"$raw" | sed 's/ $//')
  have=$(awk -v f="$field" '{print $f}' <<<"$raw")
  case $op in
    ge) sym=">="; [ "$have" -ge "$want" ] 2>/dev/null && ok=1;;
    le) sym="<="; [ "$have" -le "$want" ] 2>/dev/null && ok=1;;
    eq) sym="=";  [ "$have" -eq "$want" ] 2>/dev/null && ok=1;;
  esac
  if [ $ok -eq 1 ]; then
    msg OK "$key current=$raw (recommended $sym $want)"
  else
    msg "$lvl" "$key current=$raw recommended $sym $want - $why"
    new=$(awk -v f="$field" -v w="$want" '{$f=w; print}' <<<"$raw")
    suggest "$lvl: $why" "$key = $new"
  fi
}

# Counters
udpstat() {  # Udp|Udp6 FIELD -> value
  if [ "$1" = Udp ]; then
    awk -v f="$2" '$1=="Udp:"{ if(!h){for(i=2;i<=NF;i++) ix[$i]=i; h=1} else {print (f in ix)?$ix[f]:0} }' /proc/net/snmp 2>/dev/null
  else
    awk -v k="Udp6$2" '$1==k{print $2}' /proc/net/snmp6 2>/dev/null
  fi
}
softnet() {  # -> "dropped squeezed" summed over CPUs (hex columns 2 and 3)
  local d=0 s=0 a b c r
  while read -r a b c r; do d=$((d+16#$b)); s=$((s+16#$c)); done < /proc/net/softnet_stat
  echo "$d $s"
}
qdrop() {   # IFACE -> packets dropped by the ROOT qdisc (mq root already sums its children)
  local v s=0
  for v in $(tc -s qdisc show dev "$1" 2>/dev/null | awk '/^qdisc/{r=($0 ~ / root( |$)/)} r && /dropped/{gsub(/[(),]/,""); for(i=1;i<=NF;i++) if($i=="dropped") print $(i+1)}'); do
    isnum "$v" && s=$((s + v))
  done
  echo "$s"
}
txstat() {  # IFACE -> "name value" for every driver counter with "tx" in its name
  ethtool -S "$1" 2>/dev/null | awk -F: 'NF==2 && tolower($1) ~ /tx/ {gsub(/[ \t]/,"",$1); gsub(/[ \t]/,"",$2); if ($2 ~ /^[0-9]+$/ && tolower($1) !~ /(packets|bytes|pkts)$/) print $1, $2}'
}
rxstat() {  # IFACE -> "name value" for driver RX loss counters (names vary by driver; XDP drops excluded as intentional)
  ethtool -S "$1" 2>/dev/null | awk -F: 'NF==2 {n=$1; v=$2; gsub(/[ \t]/,"",n); gsub(/[ \t]/,"",v); l=tolower(n)
    if (v ~ /^[0-9]+$/ && l ~ /rx/ && l ~ /(drop|discard|miss|no_?buf|out_of_buf|no_dma|no_desc|fifo|overrun)/ && l !~ /xdp/ &&
        l != "rx_dropped" && l != "rx_missed_errors" && l != "rx_fifo_errors") print n, v}'
}
rxport() { [[ ${1,,} =~ (_phy$|_phy_|^phy_|^mac_) ]]; }   # counter NAME is NIC/PHY-level (e.g. mlx5 rx_discards_phy), not the host ring
rxqpkts() {  # IFACE -> "name value" for per-queue RX packet counters (ixgbe rx_queue_0_packets, i40e rx-0.packets, mlx5 rx0_packets, ...)
  ethtool -S "$1" 2>/dev/null | awk -F: 'NF==2 {n=$1; v=$2; gsub(/[ \t]/,"",n); gsub(/[ \t]/,"",v)
    if (v ~ /^[0-9]+$/ && tolower(n) ~ /^rx[-_]?(queue[-_]?)?[0-9]+[-_.]packets$/) print n, v}'
}
cpustat() {  # -> "steal total" (user..steal jiffies), summed in bash so large values stay integers
  local cpu f t=0
  read -r cpu f[1] f[2] f[3] f[4] f[5] f[6] f[7] f[8] _ < /proc/stat
  for i in 1 2 3 4 5 6 7 8; do t=$((t + ${f[$i]:-0})); done
  echo "${f[8]:-0} $t"
}

[ "$(id -u)" -ne 0 ] && msg WARN "Not running as root - process limits, timer_list and some counters may be missing"
memkb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
ncpu=$(nproc)
virt=$(systemd-detect-virt 2>/dev/null); virt=${virt:-unknown}
msg INFO "Host: $(hostname)  Kernel: $(uname -r)  CPUs: $ncpu  RAM: $((memkb/1048576)) GB  Virtualization: $virt"
msg INFO "Date: $(date -Is)  Uptime: $(uptime -p 2>/dev/null)"
msg INFO "Kernel cmdline: $(rd /proc/cmdline)"

# ---------------------------------------------------------------------------
section "Network: UDP socket buffers (SIP + RTP)"
tune WARN net.core.rmem_max      ge 16777216 1 "ceiling for socket receive buffers; SIP profiles and media sockets can't grow past it"
tune WARN net.core.wmem_max      ge 16777216 1 "ceiling for socket send buffers"
tune WARN net.core.rmem_default  ge 1048576  1 "sockets that don't set SO_RCVBUF (SIP/RTP) get this; small = UdpRcvbufErrors during registration storms or CPU stalls"
tune INFO net.core.wmem_default  ge 524288   1 "default send buffer for UDP sockets"
tune INFO net.ipv4.udp_rmem_min  ge 16384    1 "minimum per-socket receive buffer under memory pressure"
tune INFO net.ipv4.udp_wmem_min  ge 16384    1 "minimum per-socket send buffer under memory pressure"
um=$(get net.ipv4.udp_mem | xargs)
if [ -n "$um" ]; then
  read -r _ _ um3 <<<"$um"
  msg INFO "net.ipv4.udp_mem = $um (hard limit for all UDP sockets ~$((um3*4/1024)) MB) - only raise if UdpRcvbufErrors grow with MemErrors"
fi

section "Network: packet processing"
tune WARN net.core.netdev_max_backlog ge 16384 1 "per-CPU backlog; overflow = softnet drops during RTP bursts"
tune INFO net.core.netdev_budget       ge 600   1 "packets per softirq run; small RTP packets mean high packet rates"
tune INFO net.core.somaxconn           ge 4096  1 "listen backlog for SIP over TCP/TLS, WSS and ESL"
tune INFO net.ipv4.tcp_max_syn_backlog ge 4096  1 "half-open TCP backlog for SIP TCP/TLS clients reconnecting together"
tune INFO net.ipv4.tcp_keepalive_time  le 600   1 "SIP over TCP/TLS through NAT: NAT boxes drop idle mappings long before the 2h default"
rpf=$(get net.ipv4.conf.all.rp_filter)
[ -n "$rpf" ] && msg INFO "net.ipv4.conf.all.rp_filter = $rpf (1 strict, 2 loose) - strict can drop RTP on multi-homed hosts; check: nstat -az TcpExtIPReversePathFilter"

# ---------------------------------------------------------------------------
section "Port ranges"
pr=$(get net.ipv4.ip_local_port_range | xargs); resv=$(get net.ipv4.ip_local_reserved_ports)
msg INFO "net.ipv4.ip_local_port_range = $pr  ip_local_reserved_ports = ${resv:-none}"
note "Ephemeral ports: make sure your RTP port range is outside net.ipv4.ip_local_port_range, or list it in net.ipv4.ip_local_reserved_ports, so outbound connections and DNS lookups never hold media ports."

# ---------------------------------------------------------------------------
section "Connection tracking (firewall state for SIP/RTP flows)"
if [ -r /proc/sys/net/netfilter/nf_conntrack_max ]; then
  cmax=$(get net.netfilter.nf_conntrack_max); ccount=$(get net.netfilter.nf_conntrack_count)
  msg INFO "conntrack entries: $ccount / $cmax ($((ccount*100/(cmax>0?cmax:1)))%)"
  tune WARN net.netfilter.nf_conntrack_max ge 262144 1 "every call is 2-4 UDP flows (RTP+RTCP per leg) plus SIP; table full = packets silently dropped"
  [ $((ccount*100/(cmax>0?cmax:1))) -ge 80 ] && msg FAIL "conntrack table is over 80% full"
  tune INFO net.netfilter.nf_conntrack_udp_timeout_stream ge 120 1 "RTP flows on hold/silence suppression must not expire mid-call"
  note "Conntrack: consider not tracking RTP at all: iptables -t raw -A PREROUTING -p udp --dport <rtp-start>:<rtp-end> -j CT --notrack (and the same in OUTPUT for --sport), with matching ACCEPT rules."
else
  msg INFO "nf_conntrack not loaded - no connection-tracking limits apply"
fi
alg=$(lsmod 2>/dev/null | awk '$1 ~ /^nf_(conntrack|nat)_sip$/{print $1}' | paste -sd ' ')
if [ -n "$alg" ]; then
  msg FAIL "SIP ALG loaded ($alg) - rewrites SIP/SDP on the fly and commonly causes one-way audio and failed re-INVITEs on a SIP server"
  note "Remove the SIP ALG: modprobe -r nf_nat_sip nf_conntrack_sip; echo -e 'blacklist nf_nat_sip\nblacklist nf_conntrack_sip' > /etc/modprobe.d/no-sip-alg.conf"
else
  msg OK "SIP ALG (nf_conntrack_sip / nf_nat_sip) not loaded"
fi

# ---------------------------------------------------------------------------
section "Memory, threads and file handles"
tune WARN vm.swappiness       le 10      1 "swapped-out FreeSWITCH pages stall media threads"
tune WARN vm.max_map_count    ge 262144  1 "each thread needs stack mappings; thousands of channels means thousands of threads"
tune WARN kernel.threads-max  ge 32768   1 "system-wide thread cap"
tune INFO kernel.pid_max      ge 131072  1 "threads consume PIDs too"
tune INFO fs.file-max         ge 2097152 1 "system-wide open file cap"
tune INFO fs.nr_open          ge 1048576 1 "per-process ceiling for LimitNOFILE"
thp=$(sel "$(rd /sys/kernel/mm/transparent_hugepage/enabled)")
if [ "$thp" = always ]; then
  msg INFO "transparent hugepages = always - compaction can cause latency spikes; madvise is the safer choice for a media server"
  note "THP: echo madvise > /sys/kernel/mm/transparent_hugepage/enabled (persist with transparent_hugepage=madvise on the kernel cmdline)"
elif [ -n "$thp" ]; then
  msg OK "transparent hugepages = $thp"
fi
swapused=$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{print int((t-f)/1024)}' /proc/meminfo)
[ "$swapused" -gt 0 ] && msg INFO "system swap in use: $swapused MB"

# ---------------------------------------------------------------------------
section "Timing (RTP is paced by kernel timers)"
cs=$(rd /sys/devices/system/clocksource/clocksource0/current_clocksource)
case $cs in
  tsc|kvm-clock|arch_sys_counter) msg OK "clocksource = $cs (available: $(rd /sys/devices/system/clocksource/clocksource0/available_clocksource))";;
  "") msg INFO "clocksource not readable";;
  *) msg WARN "clocksource = $cs - slow/jittery source; expect timer jitter in RTP pacing (available: $(rd /sys/devices/system/clocksource/clocksource0/available_clocksource))";;
esac
hres=$(awk '/hres_active/{print $3; exit}' /proc/timer_list 2>/dev/null)
case $hres in
  1) msg OK "high-resolution timers active";;
  0) msg FAIL "high-resolution timers NOT active - FreeSWITCH's 10/20ms timers will be coarse";;
  *) msg INFO "high-resolution timer state unknown (needs root to read /proc/timer_list)";;
esac
hz=$(grep -m1 '^CONFIG_HZ=' "/boot/config-$(uname -r)" 2>/dev/null)
[ -n "$hz" ] && msg INFO "kernel $hz"
ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
case $ntp in
  yes) msg OK "system clock NTP-synchronized";;
  no)  msg WARN "system clock NOT NTP-synchronized - CDR timestamps, TLS and SIP auth nonces drift";;
  *)   msg INFO "NTP sync state unknown (no timedatectl)";;
esac

# ---------------------------------------------------------------------------
section "CPU"
govs=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | awk '{printf "%s(%s) ", $2, $1}')
if [ -z "$govs" ]; then
  msg INFO "no cpufreq governor exposed (VM, or frequency fixed by firmware)"
elif grep -qv '^performance(' <<<"$(tr ' ' '\n' <<<"$govs" | grep .)"; then
  msg WARN "CPU governor: $govs- frequency ramp-up adds latency on bursty media load; performance is preferred (driver: $(rd /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver))"
  note "CPU governor, now: cpupower frequency-set -g performance (Debian: apt install linux-cpupower). Persist it with a oneshot unit /etc/systemd/system/cpu-performance.service: [Service] Type=oneshot ExecStart=/usr/bin/cpupower frequency-set -g performance RemainAfterExit=yes [Install] WantedBy=multi-user.target, then systemctl enable --now cpu-performance.service. Or use tuned-adm profile latency-performance (also limits C-states) - not both. Also set the BIOS power profile to OS control / max performance. Guide section 14."
else
  # performance now - but will it survive a reboot? Look for whatever sets it at boot.
  persist=""
  grep -q '^CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y' "/boot/config-$(uname -r)" 2>/dev/null && persist+="kernel default (CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE) "
  grep -q 'cpufreq.default_governor=performance' /proc/cmdline && persist+="kernel cmdline cpufreq.default_governor "
  units=$(grep -lsE 'frequency-set[^#]*(-g|--governor)[ =]*performance|performance[^#]*scaling_governor|scaling_governor[^#]*performance' \
            /etc/systemd/system/*.service /etc/systemd/system/*/*.conf /etc/rc.local /etc/network/interfaces 2>/dev/null | xargs -r -n1 basename | paste -sd ' ')
  [ -n "$units" ] && persist+="boot script ($units) "
  if has tuned-adm && systemctl is-active -q tuned 2>/dev/null; then
    tp=$(tuned-adm active 2>/dev/null | sed -n 's/^Current active profile: //p'); persist+="tuned profile ${tp:-?} "
  fi
  grep -qsE '^[[:space:]]*GOVERNOR=.?performance' /etc/default/cpufrequtils && persist+="cpufrequtils "
  grep -qsE 'scaling_governor[[:space:]]*=[[:space:]]*performance' /etc/sysfs.conf /etc/sysfs.d/*.conf && persist+="sysfsutils "
  if [ -n "$persist" ]; then
    msg OK "CPU governor: $govs(set at boot by: ${persist% })"
  else
    msg INFO "CPU governor: $govs- but nothing found that sets it at boot (no unit, tuned profile, sysfsutils or kernel default); it may revert to powersave/schedutil after a reboot"
    note "CPU governor persistence: on Debian 12/13 add a oneshot unit /etc/systemd/system/cpu-performance.service running /usr/bin/cpupower frequency-set -g performance (package linux-cpupower), WantedBy=multi-user.target, then systemctl enable cpu-performance.service. Guide section 14."
  fi
fi
cst=$(grep -oE '(intel_idle\.max_cstate|processor\.max_cstate|idle)=[^ ]+' /proc/cmdline | paste -sd ' ')
msg INFO "C-state limits on cmdline: ${cst:-none (deep C-states allowed; limit them only if you see wake-up jitter)}"
if has systemctl; then
  irqb=$(systemctl is-active irqbalance 2>/dev/null)
  msg INFO "irqbalance: ${irqb:-not installed} (spreads NIC interrupts across CPUs; disable only if you pin IRQs by hand)"
fi
msg INFO "kernel.sched_rt_runtime_us = $(get kernel.sched_rt_runtime_us) (realtime threads may use this much of each second; -1 = no throttle)"

# ---------------------------------------------------------------------------
section "Physical NICs (rings, queues, txqueuelen, drops)"
dq=$(get net.core.default_qdisc)
msg INFO "net.core.default_qdisc = ${dq:-?} (qdisc new interfaces get; fq_codel keeps egress queues short without hurting steady RTP)"
ring_of() {  # IFACE RX|TX -> "max cur"
  ethtool -g "$1" 2>/dev/null | awk -v k="$2:" '/^Pre-set/{s=1} /^Current/{s=2} $1==k{if(s==1)m=$2; else if(s==2)c=$2} END{print m, c}'
}
nnic=0; PHYS=(); declare -A TXCUR TXMAX RXCUR RXMAX QCUR QMAX DRV HASHST
for n in /sys/class/net/*; do
  i=$(basename "$n"); [ -e "$n/device" ] || continue
  nnic=$((nnic+1)); PHYS+=("$i")
  drv=$(basename "$(readlink -f "$n/device/driver" 2>/dev/null)" 2>/dev/null); DRV[$i]=$drv
  drops=0   # ring/FIFO overflow per the generic counters; rx_dropped is reported separately (often not buffer-related)
  for c in rx_missed_errors rx_fifo_errors; do v=$(rd "$n/statistics/$c"); drops=$((drops+${v:-0})); done
  rxd=$(rd "$n/statistics/rx_dropped"); rxd=${rxd:-0}
  rring="?"; rcur=""; rmax=""; tring="?"; tcur=""; tmax=""; chan="?"; qcur=""; qmax=""; coal=""
  hostc=""; portc=""
  if has ethtool; then
    read -r rmax rcur <<<"$(ring_of "$i" RX)"; [ -n "$rcur" ] && rring="$rcur/$rmax"
    read -r tmax tcur <<<"$(ring_of "$i" TX)"; [ -n "$tcur" ] && tring="$tcur/$tmax"
    TXCUR[$i]=$tcur; TXMAX[$i]=$tmax; RXCUR[$i]=$rcur; RXMAX[$i]=$rmax
    read -r qmax qcur <<<"$(ethtool -l "$i" 2>/dev/null | awk '/^Pre-set/{s=1} /^Current/{s=2} /^Combined:/{if(s==1)m=$2; else if(s==2)c=$2} END{print m, c}')"
    [ -n "$qcur" ] && chan="$qcur/$qmax"; QCUR[$i]=$qcur; QMAX[$i]=$qmax
    coal=$(ethtool -c "$i" 2>/dev/null | awk '/^Adaptive RX:/{a=$3} /^rx-usecs:/{u=$2} END{if(a!=""||u!="") printf "adaptive-rx %s rx-usecs %s", (a==""?"?":a), (u==""?"?":u)}')
    # driver-specific RX loss counters, split into host-ring and NIC/port-level
    while read -r k v; do
      { [ -z "$k" ] || [ "$v" = 0 ]; } && continue
      if rxport "$k"; then portc+="$k=$v "; else hostc+="$k=$v "; fi
    done < <(rxstat "$i")
  fi
  msg INFO "$i: driver ${drv:-?}  speed $(rd "$n/speed")Mb/s  rings cur/max: rx $rring tx $tring  combined queues $chan${coal:+  coalescing: $coal}"
  hostc=${hostc% }; portc=${portc% }
  msg INFO "$i: RX since boot: missed/fifo $drops  rx_dropped $rxd  driver ring counters: ${hostc:-none non-zero}  port/PHY counters: ${portc:-none non-zero}"

  # Ring overflow evidence: generic missed/fifo, or the driver's own host-side counters
  ringev=0; { [ "$drops" -gt 0 ] || [ -n "$hostc" ]; } && ringev=1
  belowmax=0; isnum "$rcur" && isnum "$rmax" && [ "$rcur" -lt "$rmax" ] && belowmax=1
  if [ $ringev -eq 1 ] && [ $belowmax -eq 1 ]; then
    msg WARN "$i: RX ring has overflowed since boot and is at $rcur of max $rmax - raise it to max (see Suggested NIC settings; the live sample shows whether it's happening now)"
    nicfix "$i" rxring "$rmax" "$i: RX ring overflowed since boot at $rcur - raise to max"
  elif [ $ringev -eq 1 ]; then
    msg WARN "$i: RX ring has overflowed since boot and is already at max ($rmax) - the CPU side isn't keeping up; spread the load (queues, IRQs, UDP hash) rather than buffering more"
    note "$i RX ring at max and still overflowing: 1) ethtool -l $i - use all combined queues; 2) check its IRQs land on several CPUs: grep -E '$i|${drv:-$i}' /proc/interrupts; 3) UDP hash must include ports (see the rx-flow-hash line); 4) look for busy CPUs in softirq: mpstat -P ALL 1 (%soft)."
  elif [ "$rxd" -gt 0 ] && [ -z "$portc" ]; then
    msg INFO "$i rx_dropped=$rxd with no ring overflows - usually discarded traffic (unknown protocol, unconfigured VLAN, standby bond slave), not a buffer problem"
  fi
  if [ -n "$portc" ]; then
    msg WARN "$i: NIC/port-level RX drops since boot ($portc) - the NIC's own buffer overflowed before packets reached the ring; a bigger ring won't fix this"
    note "$i port/PHY RX drops: check PCIe link (lspci -vv: LnkSta speed/width vs LnkCap), flow control (ethtool -a $i), and whether the NIC's queues are being drained (see the ring checks)."
  fi

  # Small default ring with no evidence yet: suggest a moderate preemptive raise
  if [ $ringev -eq 0 ] && isnum "$rcur" && isnum "$rmax" && [ "$rcur" -le 512 ] && [ "$rmax" -gt "$rcur" ]; then
    want=$(( rmax < 2048 ? rmax : 2048 ))
    msg INFO "$i: RX ring at $rcur (max $rmax) - small for a high packet-rate media server; $want gives $((want/rcur))x the stall headroom (see fill time in the live sample)"
    nicfix "$i" rxring "$want" "$i: RX ring $rcur of max $rmax - preemptive raise"
  fi
  case $drv in virtio_net|virtio-pci|virtio_pci)
    note "$i is virtio (VM guest): the RX ring maximum is set by the hypervisor (QEMU rx_queue_size, up to 1024), and when this ring overflows the drop is counted on the HOST, as tx_dropped on the VM's tap interface - check there, not only here.";;
  esac

  # RSS: with several queues, the UDP hash must include ports or one carrier's RTP lands on one CPU
  if isnum "$qcur" && [ "$qcur" -gt 1 ] && has ethtool; then
    fh=$(ethtool -n "$i" rx-flow-hash udp4 2>/dev/null)
    if grep -q 'L4 bytes' <<<"$fh"; then
      msg OK "$i: UDP RSS hash includes ports - RTP spreads across $qcur queues"; HASHST[$i]="UDP hash includes ports"
    elif grep -q 'IP SA' <<<"$fh"; then
      msg WARN "$i: UDP RSS hash uses IP addresses only - all RTP between two hosts (e.g. you and one carrier/SBC) lands on ONE queue and ONE CPU"; HASHST[$i]="UDP hash IP-only"
      nicfix "$i" hash sdfn "$i: UDP RSS hash ignores ports - hash on ports so RTP spreads across queues"
    else
      msg INFO "$i: UDP RSS hash not reported by the driver (ethtool -n $i rx-flow-hash udp4)"; HASHST[$i]="UDP hash not reported by driver"
    fi
  fi
  if isnum "$qcur" && isnum "$qmax" && [ "$qcur" -lt "$qmax" ] && [ "$qcur" -lt "$ncpu" ]; then
    qwant=$(( qmax < ncpu ? qmax : ncpu ))
    msg INFO "$i: using $qcur of $qmax combined queues on a $ncpu-CPU host - more queues spread RX across more CPUs (ethtool -L $i combined $qwant)"
    nicfix "$i" queues "$qwant" "$i: $qcur of $qmax combined queues on $ncpu CPUs - use more"
  fi

  # TX side: tx_dropped is cumulative since the interface came up
  ql=$(rd "$n/tx_queue_len"); td=$(rd "$n/statistics/tx_dropped"); td=${td:-0}; txp=$(rd "$n/statistics/tx_packets")
  qd=$(tc qdisc show dev "$i" 2>/dev/null | awk 'NR==1{print $2}')
  msg INFO "$i: qdisc ${qd:-?}  txqueuelen ${ql:-?}  tx_dropped $td of ${txp:-?} packets"
  if [ "$td" -gt 0 ]; then
    where="the live sample below shows whether new drops are in the qdisc or the driver"
    isnum "$SAMPLE" && [ "$SAMPLE" -gt 0 ] || where="run with SAMPLE=30 during load to see whether new drops are in the qdisc or the driver"
    qtot="?"; has tc && qtot=$(qdrop "$i")
    msg WARN "$i has $td tx drops since the interface came up; root qdisc (${qd:-?}) reports $qtot dropped since it was created - $where"
  fi
done
[ $nnic -eq 0 ] && msg INFO "no physical NICs found (VM with virtio is reported as physical; containers have none)"

# ---------------------------------------------------------------------------
section "Drop counters since boot"
u_rcv=$(udpstat Udp RcvbufErrors); u_snd=$(udpstat Udp SndbufErrors)
u_in=$(udpstat Udp InErrors);      u_mem=$(udpstat Udp MemErrors)
u6_rcv=$(udpstat Udp6 RcvbufErrors)
msg INFO "UDP: RcvbufErrors=${u_rcv:-?} SndbufErrors=${u_snd:-?} InErrors=${u_in:-?} MemErrors=${u_mem:-?}  UDP6 RcvbufErrors=${u6_rcv:-?}"
if [ "${u_rcv:-0}" -gt 0 ] || [ "${u6_rcv:-0}" -gt 0 ]; then
  msg WARN "UDP receive buffers have overflowed since boot - FreeSWITCH (or something) didn't read its sockets fast enough at some point"
else
  msg OK "no UDP receive-buffer overflows since boot"
fi
[ "${u_mem:-0}" -gt 0 ] && msg WARN "UDP MemErrors=$u_mem - global udp_mem limit was hit"
read -r sd ss <<<"$(softnet)"
if [ "$sd" -gt 0 ]; then
  msg WARN "softnet backlog drops since boot: $sd (time_squeeze $ss) - per-CPU backlog overflowed"
  i=0; while read -r a b r; do
    v=$((16#$b)); [ "$v" -gt 0 ] && msg INFO "  softnet row $i (CPU) dropped $v"; i=$((i+1))
  done < /proc/net/softnet_stat
else
  msg OK "no softnet backlog drops since boot (time_squeeze $ss)"
fi
read -r st0 tt0 <<<"$(cpustat)"
if [ "$virt" != none ] && [ "${tt0:-0}" -gt 0 ]; then
  msg INFO "CPU steal since boot: $((st0*1000/tt0/10)).$((st0*1000/tt0%10))% (time the hypervisor ran someone else on your vCPUs)"
fi


if isnum "$SAMPLE" && [ "$SAMPLE" -gt 0 ]; then
  section "Live ${SAMPLE}s sample (is it happening right now?)"
  a_rcv=$(udpstat Udp RcvbufErrors); a_in=$(udpstat Udp InErrors); read -r a_sd _ <<<"$(softnet)"; read -r a_st a_tt <<<"$(cpustat)"
  declare -A A_TXD A_QD A_TXS A_CAR A_RXM A_RXS A_RXP A_RXQ
  rxmiss() { local c v s=0; for c in rx_missed_errors rx_fifo_errors; do v=$(rd "/sys/class/net/$1/statistics/$c"); s=$((s + ${v:-0})); done; echo "$s"; }
  for i in "${PHYS[@]}"; do
    A_TXD[$i]=$(rd "/sys/class/net/$i/statistics/tx_dropped"); A_CAR[$i]=$(rd "/sys/class/net/$i/carrier_changes")
    A_RXM[$i]=$(rxmiss "$i"); A_RXP[$i]=$(rd "/sys/class/net/$i/statistics/rx_packets")
    has tc && A_QD[$i]=$(qdrop "$i")
    if has ethtool; then A_TXS[$i]=$(txstat "$i"); A_RXS[$i]=$(rxstat "$i"); A_RXQ[$i]=$(rxqpkts "$i"); fi
  done
  sleep "$SAMPLE"
  b_rcv=$(udpstat Udp RcvbufErrors); b_in=$(udpstat Udp InErrors); read -r b_sd _ <<<"$(softnet)"; read -r b_st b_tt <<<"$(cpustat)"
  d=$(( ${b_rcv:-0} - ${a_rcv:-0} ))
  if [ "$d" -gt 0 ]; then msg FAIL "UDP RcvbufErrors grew by $d in ${SAMPLE}s - packets (SIP or RTP) are being dropped now"
  else msg OK "no new UDP receive-buffer drops"; fi
  d=$(( ${b_in:-0} - ${a_in:-0} )); [ "$d" -gt 0 ] && msg WARN "UDP InErrors grew by $d in ${SAMPLE}s"
  d=$((b_sd - a_sd))
  if [ "$d" -gt 0 ]; then msg FAIL "softnet drops grew by $d in ${SAMPLE}s"; else msg OK "no new softnet drops"; fi
  ct=$((b_tt - a_tt))
  if [ "$virt" != none ] && [ "$ct" -gt 0 ]; then
    sp=$(( (b_st - a_st) * 1000 / ct ))
    if [ "$sp" -ge 20 ]; then msg WARN "CPU steal $((sp/10)).$((sp%10))% right now - the hypervisor is starving this VM; expect RTP jitter"
    else msg OK "CPU steal $((sp/10)).$((sp%10))% right now"; fi
  fi

  # TX loss location: interface tx_dropped vs root qdisc dropped over the same window
  for i in "${PHYS[@]}"; do
    dtx=$(( $(rd "/sys/class/net/$i/statistics/tx_dropped") - ${A_TXD[$i]:-0} ))
    dcar=$(( $(rd "/sys/class/net/$i/carrier_changes" || echo 0) - ${A_CAR[$i]:-0} ))
    dqd=""; has tc && dqd=$(( $(qdrop "$i") - ${A_QD[$i]:-0} ))
    grown=""
    if has ethtool; then
      declare -A before=(); while read -r k v; do [ -n "$k" ] && before[$k]=$v; done <<<"${A_TXS[$i]}"
      while read -r k v; do
        [ -n "$k" ] && isnum "$v" && isnum "${before[$k]}" && [ "$v" -gt "${before[$k]}" ] && grown+="$k+$((v - ${before[$k]})) "
      done < <(txstat "$i")
      unset before
    fi
    if [ "$dtx" -le 0 ] && [ "${dqd:-0}" -le 0 ]; then
      msg OK "$i: no new TX drops (interface or qdisc)${grown:+  - driver TX counters that moved: $grown}"
    elif [ -z "$dqd" ]; then
      msg FAIL "$i: tx_dropped grew by $dtx in ${SAMPLE}s - install iproute2 (tc) to tell qdisc drops from driver drops"
    elif [ "$dqd" -gt 0 ]; then
      msg FAIL "$i: qdisc dropped +$dqd (interface tx_dropped +$dtx) in ${SAMPLE}s - loss is in the QDISC, not the TX ring"
      note "$i qdisc drops: tc -s qdisc show dev $i. drop_overlimit = queue limit hit (pfifo_fast: raise txqueuelen, or switch to fq_codel); CoDel drops = packets sat too long, i.e. the link or one flow is congested. Do not raise the TX ring for this."
    else
      msg FAIL "$i: interface tx_dropped +$dtx with no qdisc drops in ${SAMPLE}s - loss is in the DRIVER/core. Driver TX counters that moved: ${grown:-none (driver does not expose them)}"
      if [ "$dcar" -gt 0 ]; then
        note "$i: carrier changed $dcar time(s) during the sample - packets are dropped while the link is down; fix the link (cable, switch port, autoneg), not the ring."
      elif grep -qiE 'dma|timeout|hang|err' <<<"$grown"; then
        note "$i: driver TX fault counters moved ($grown) - a bigger ring won't help. Check dmesg for NETDEV WATCHDOG, driver/firmware versions (ethtool -i $i)."
      elif isnum "${TXCUR[$i]}" && isnum "${TXMAX[$i]}" && [ "${TXCUR[$i]}" -lt "${TXMAX[$i]}" ]; then
        note "$i: driver-level TX drops with the TX ring at ${TXCUR[$i]} of max ${TXMAX[$i]} - this is the case where raising it can help (added to Suggested NIC settings). Restart/busy counters alone are backpressure, not loss."
        nicfix "$i" txring "${TXMAX[$i]}" "$i: driver-level TX drops in the live sample with TX ring at ${TXCUR[$i]} - raise to max"
      else
        note "$i: driver-level TX drops with the TX ring already at max - check ethtool -S $i for the counter that matches, and BQL: /sys/class/net/$i/queues/tx-*/byte_queue_limits/{limit,inflight}"
      fi
    fi
  done

  # RX: new ring overflows, and how much stall the RX ring can absorb at the current packet rate
  cdelta() {  # "BEFORE name value lines" "AFTER name value lines" -> "name+delta ..." for counters that grew
    local -A b=(); local k v out=""
    while read -r k v; do [ -n "$k" ] && b[$k]=$v; done <<<"$1"
    while read -r k v; do
      [ -n "$k" ] && isnum "$v" && isnum "${b[$k]}" && [ "$v" -gt "${b[$k]}" ] && out+="$k+$((v - ${b[$k]})) "
    done <<<"$2"
    echo "$out"
  }
  for i in "${PHYS[@]}"; do
    dm=$(( $(rxmiss "$i") - ${A_RXM[$i]:-0} ))
    dp=$(( $(rd "/sys/class/net/$i/statistics/rx_packets") - ${A_RXP[$i]:-0} ))
    hostg=""; portg=""; qmaxd=0; qname=""
    if has ethtool; then
      for kv in $(cdelta "${A_RXS[$i]}" "$(rxstat "$i")"); do
        if rxport "${kv%%+*}"; then portg+="$kv "; else hostg+="$kv "; fi
      done
      for kv in $(cdelta "${A_RXQ[$i]}" "$(rxqpkts "$i")"); do   # busiest RX queue in the window
        v=${kv##*+}; [ "$v" -gt "$qmaxd" ] && { qmaxd=$v; qname=${kv%%+*}; }
      done
    fi
    rcur=${RXCUR[$i]}; rmax=${RXMAX[$i]}

    if [ "$dm" -gt 0 ] || [ -n "$hostg" ]; then
      ev=""; [ "$dm" -gt 0 ] && ev="rx_missed/fifo+$dm "; ev+=$hostg
      msg FAIL "$i: RX ring overflowing NOW - ${ev% } in ${SAMPLE}s"
      if isnum "$rcur" && isnum "$rmax" && [ "$rcur" -lt "$rmax" ]; then
        nicfix "$i" rxring "$rmax" "$i: RX ring overflowing during the live sample at $rcur - raise to max"
      else
        note "$i: live RX ring overflow with the ring at max - spread the load: all combined queues (ethtool -L), IRQs on several CPUs, UDP hash with ports, and find the CPU stuck in softirq (mpstat -P ALL 1)."
      fi
    else
      msg OK "$i: no new RX ring overflows"
    fi
    [ -n "$portg" ] && msg FAIL "$i: NIC/port-level RX drops NOW (${portg% }) - the NIC's own buffer is overflowing; check PCIe link and flow control, not the ring"

    # Fill time: how long the RX ring absorbs a stalled CPU at the busiest queue's packet rate
    if isnum "$rcur" && [ "$rcur" -gt 0 ] && [ "$dp" -le 0 ]; then
      msg INFO "$i: no RX traffic during the sample - ring headroom not estimated"
    elif isnum "$rcur" && [ "$rcur" -gt 0 ]; then
      pps=$(( dp / SAMPLE ))
      if [ "$qmaxd" -gt 0 ]; then
        qpps=$(( qmaxd / SAMPLE )); basis="busiest queue $qname"
      elif isnum "${QCUR[$i]}" && [ "${QCUR[$i]}" -gt 0 ]; then
        qpps=$(( pps / ${QCUR[$i]} )); basis="average of ${QCUR[$i]} queues (driver has no per-queue counters; the busiest queue may be higher)"
      else
        qpps=$pps; basis="single queue"
      fi
      [ "$qpps" -gt "$pps" ] && qpps=$pps   # never more than the interface total
      if [ "$qpps" -le 0 ]; then
        msg INFO "$i: RX ~$pps pps - too little traffic to estimate ring headroom; re-run at peak"
      else
        fill=$(( rcur * 1000 / qpps ))
        line="$i: RX ~$pps pps, ~$qpps pps on the $basis -> RX ring of $rcur fills in ~${fill} ms if that CPU stalls"
        if [ "$fill" -lt 10 ]; then
          msg WARN "$line - under 10 ms; a short softirq or SMI stall will drop packets"
          isnum "$rmax" && [ "$rcur" -lt "$rmax" ] && nicfix "$i" rxring "$rmax" "$i: RX ring fills in ~${fill} ms at current load - max $rmax gives ~$(( rmax * 1000 / qpps )) ms"
        elif [ "$fill" -lt 20 ]; then
          msg INFO "$line - under one 20 ms RTP interval; consider a larger ring${rmax:+ (max $rmax)}"
          isnum "$rmax" && [ "$rcur" -lt "$rmax" ] && nicfix "$i" rxring "$rmax" "$i: RX ring fills in ~${fill} ms at current load - max $rmax gives ~$(( rmax * 1000 / qpps )) ms"
        else
          msg OK "$line"
        fi
        [ "$pps" -lt 1000 ] && msg INFO "$i: traffic during the sample was light - fill time at peak will be lower; re-run during your busiest hour"
      fi
    fi
  done
fi

# ---------------------------------------------------------------------------
section "Kernel log"
klog=$(dmesg -T 2>/dev/null); [ -z "$klog" ] && klog=$(journalctl -k -b --no-pager 2>/dev/null)
if [ -z "$klog" ]; then
  msg INFO "kernel log not readable (run as root)"
else
  hits=0
  chk() {  # LEVEL PATTERN "what"
    local n last; n=$(grep -cE "$2" <<<"$klog")
    if [ "$n" -gt 0 ]; then hits=$((hits+1)); last=$(grep -E "$2" <<<"$klog" | tail -1); msg "$1" "$3: $n line(s), last: $last"; fi
  }
  chk FAIL 'nf_conntrack: table full'                                  "conntrack table full (dropped packets)"
  chk FAIL 'Out of memory: Killed process'                             "OOM killer fired"
  chk WARN 'neighbou?r table overflow'                                 "ARP/neighbour table overflow"
  chk WARN 'clocksource.*unstable|Marking clocksource'                  "clocksource instability"
  chk WARN 'hrtimer: interrupt took'                                   "slow timer interrupts"
  chk WARN 'NETDEV WATCHDOG|Link is Down'                              "NIC link drops / transmit timeouts"
  [ $hits -eq 0 ] && msg OK "no conntrack, OOM, clock, timer or NIC link problems in the kernel log"
fi

# ---------------------------------------------------------------------------
section "Summary"
msg INFO "OK: $NOK  WARN: $NWARN  FAIL: $NFAIL"
note "Other files in /etc/sysctl.d, /run/sysctl.d and /usr/lib/sysctl.d can override yours - they apply alphabetically and the last one wins: grep -r <key> /etc/sysctl.d /usr/lib/sysctl.d"

if [ ${#SUGGEST[@]} -gt 0 ]; then
  echo
  echo "# ---- Suggested /etc/sysctl.d/90-freeswitch.conf (review before applying) ----"
  printf '%s\n' "${SUGGEST[@]}"
  echo "# Apply: sysctl --system"
fi
if [ "$nnic" -gt 0 ]; then
  echo
  echo "# ---- Suggested NIC settings (review before applying) ----"
  if ! has ethtool; then
    echo "# ethtool is not installed - ring, queue and UDP hash checks were skipped. Install it (package: ethtool) and re-run."
  elif [ ${#NICVAL[@]} -eq 0 ]; then
    echo "# No NIC changes suggested. Per-NIC status:"
  else
    echo "# MAINTENANCE WINDOW: ethtool -G and -L reinitialise the NIC on many drivers - the link drops"
    echo "# for a second or two and live calls lose audio. Not persistent: see guide section 14."
  fi
  for i in "${PHYS[@]}"; do
    has ethtool || break
    if [ -z "${NICVAL[$i rxring]}${NICVAL[$i queues]}${NICVAL[$i hash]}${NICVAL[$i txring]}" ]; then
      # Say why nothing is suggested, so an empty block isn't mistaken for a failed check
      st="RX ring ${RXCUR[$i]:-?}/${RXMAX[$i]:-?}"
      if ! isnum "${RXCUR[$i]}"; then st+=" (driver doesn't report ring sizes)"
      elif [ "${RXCUR[$i]}" -ge "${RXMAX[$i]:-0}" ]; then st+=" (at max)"
      else st+=" (above the 512 preemptive threshold, no overflows or short fill time seen)"; fi
      st+=", queues ${QCUR[$i]:-?}/${QMAX[$i]:-?}"
      isnum "${QCUR[$i]}" && [ "${QCUR[$i]}" -le 1 ] && st+=" (single queue - UDP hash not applicable)"
      [ -n "${HASHST[$i]}" ] && st+=", ${HASHST[$i]}"
      echo "# --- $i: no changes - $st"
      continue
    fi
    echo "# --- $i ---"
    if [ -n "${NICVAL[$i rxring]}" ]; then echo "# ${NICWHY[$i rxring]}"; echo "ethtool -G $i rx ${NICVAL[$i rxring]}"; fi
    if [ -n "${NICVAL[$i txring]}" ]; then echo "# ${NICWHY[$i txring]}"; echo "ethtool -G $i tx ${NICVAL[$i txring]}"; fi
    if [ -n "${NICVAL[$i queues]}" ]; then echo "# ${NICWHY[$i queues]}"; echo "ethtool -L $i combined ${NICVAL[$i queues]}"; fi
    if [ -n "${NICVAL[$i hash]}" ]; then
      echo "# ${NICWHY[$i hash]}"; echo "ethtool -N $i rx-flow-hash udp4 sdfn"; echo "ethtool -N $i rx-flow-hash udp6 sdfn"
    fi
    # Persistence equivalents for this NIC
    link=""; nm=""
    [ -n "${NICVAL[$i rxring]}" ] && { link+="RxBufferSize=${NICVAL[$i rxring]} "; nm+="ethtool.ring-rx ${NICVAL[$i rxring]} "; }
    [ -n "${NICVAL[$i txring]}" ] && { link+="TxBufferSize=${NICVAL[$i txring]} "; nm+="ethtool.ring-tx ${NICVAL[$i txring]} "; }
    [ -n "${NICVAL[$i queues]}" ] && { link+="CombinedChannels=${NICVAL[$i queues]} "; nm+="ethtool.channels-combined ${NICVAL[$i queues]} "; }
    [ -n "$link" ] && echo "# persist: systemd .link [Link] ${link% } | nmcli connection modify <conn> ${nm% } | ifupdown: post-up the commands above"
    [ -n "${NICVAL[$i hash]}" ] && echo "# persist the UDP hash with a oneshot unit (.link and NetworkManager can't set it): guide section 14, nic-udp-hash.service"
  done
  [ ${#NICVAL[@]} -gt 0 ] && echo "# Verify: ethtool -g <nic>; ethtool -l <nic>; ethtool -n <nic> rx-flow-hash udp4; then re-run this audit at peak"
  [ "$(id -u)" -ne 0 ] && echo "# Not run as root: some ethtool queries may have failed - re-run with sudo for complete NIC results"
fi
if [ ${#NOTES[@]} -gt 0 ]; then
  echo
  for n in "${NOTES[@]}"; do msg NOTE "$n"; done
fi