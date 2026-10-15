#!/usr/bin/env bash
# kvm-tuning-audit.sh - read-only audit of kernel tunings for a baremetal KVM hypervisor (SolusVM)
# Compares current values to typical recommendations for a large KVM host running 10-20+ VMs.
# Makes NO changes. Prints a suggested sysctl.d file and non-sysctl notes at the end.
# Usage (as root):  bash kvm-tuning-audit.sh | tee kvm-tuning-report.txt

ID=0; NOK=0; NWARN=0; NFAIL=0; SUGGEST=(); NOTES=()
RX_RING_TARGET=4096   # preventive RX ring baseline for hypervisor NICs (capped at each NIC's hardware max)

msg() {  # LEVEL TEXT
  ID=$((ID+1)); printf '[%04d] %-4s %s\n' "$ID" "$1" "$2"
  case $1 in OK) NOK=$((NOK+1));; WARN) NWARN=$((NWARN+1));; FAIL) NFAIL=$((NFAIL+1));; esac
}
section() { ID=$((ID+1)); printf '\n[%04d] ==== %s ====\n' "$ID" "$1"; }
get() { sysctl -n "$1" 2>/dev/null; }
rd()  { cat "$1" 2>/dev/null; }
note() { NOTES+=("$1"); }
sel() { grep -o '\[[^]]*\]' <<<"$1" | tr -d '[]'; }   # selected value from "a [b] c"
# Drop % = dropped / (packets + dropped). Levels: < 0.01% INFO (noise), < 1% WARN, >= 1% FAIL.
droppct() { awk -v d="$1" -v p="$2" 'BEGIN{t=d+p; if(t==0) print "0.0000"; else printf "%.4f", d*100/t}'; }
droplvl() { awk -v x="$1" 'BEGIN{ if (x>=1) print "FAIL"; else if (x>=0.01) print "WARN"; else print "INFO" }'; }

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
    SUGGEST+=("# [$(printf '%04d' $ID)] $lvl: $why" "$key = $new")
  fi
}

[ "$(id -u)" -ne 0 ] && msg WARN "Not running as root - some values may be missing"
memkb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
ncpu=$(nproc)
nnodes=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l)
msg INFO "Host: $(hostname)  Kernel: $(uname -r)  CPUs: $ncpu  NUMA nodes: $nnodes  RAM: $((memkb/1048576)) GB"
msg INFO "Date: $(date -Is)  Uptime: $(uptime -p 2>/dev/null)"
msg INFO "Kernel cmdline: $(rd /proc/cmdline)"

# ---------------------------------------------------------------------------
section "Network: packet processing (affects VM traffic)"
tune WARN net.core.netdev_max_backlog ge 16384 1 "per-CPU backlog; overflow = softnet drops on bursts"
tune WARN net.core.netdev_budget       ge 600   1 "packets per softirq run; low = time_squeeze"
tune INFO net.core.netdev_budget_usecs ge 4000  1 "time per softirq run"
drops=0; squeeze=0
while read -r _ d s _; do drops=$((drops+16#$d)); squeeze=$((squeeze+16#$s)); done < /proc/net/softnet_stat
[ $drops -gt 0 ] && msg WARN "softnet drops since boot: $drops (check per-CPU: sar -n SOFT -P ALL)" || msg OK "softnet drops since boot: 0"
msg INFO "softnet time_squeeze since boot: $squeeze"

section "Network: ARP / IPv6 neighbour tables"
tune WARN net.ipv4.neigh.default.gc_thresh1 ge 1024 1 "ARP GC floor"
tune WARN net.ipv4.neigh.default.gc_thresh2 ge 4096 1 "ARP soft limit"
tune WARN net.ipv4.neigh.default.gc_thresh3 ge 8192 1 "ARP hard limit; overflow drops traffic"
tune WARN net.ipv6.neigh.default.gc_thresh1 ge 1024 1 "ND GC floor"
tune WARN net.ipv6.neigh.default.gc_thresh2 ge 4096 1 "ND soft limit"
tune WARN net.ipv6.neigh.default.gc_thresh3 ge 8192 1 "ND hard limit; overflow drops traffic"
msg INFO "Current neighbour entries: IPv4=$(ip -4 neigh show 2>/dev/null | wc -l) IPv6=$(ip -6 neigh show 2>/dev/null | wc -l)"

section "Network: filtering / routing"
if [ -d /proc/sys/net/bridge ]; then
  tune WARN net.bridge.bridge-nf-call-iptables  eq 0 1 "bridged VM traffic passes iptables/conntrack"
  tune WARN net.bridge.bridge-nf-call-ip6tables eq 0 1 "bridged VM traffic passes ip6tables"
  tune WARN net.bridge.bridge-nf-call-arptables eq 0 1 "bridged ARP passes arptables"
else
  msg OK "br_netfilter not loaded (bridged traffic bypasses iptables)"
fi
cmax=$(get net.netfilter.nf_conntrack_max)
if [ -n "$cmax" ]; then
  tune WARN net.netfilter.nf_conntrack_max ge 262144 1 "conntrack table full = new connections dropped"
  ccnt=$(get net.netfilter.nf_conntrack_count); msg INFO "conntrack usage: $ccnt / $cmax ($((ccnt*100/cmax))%)"
  hs=$(rd /sys/module/nf_conntrack/parameters/hashsize)
  if [ -n "$hs" ] && [ "$hs" -lt $((cmax/8)) ]; then
    msg WARN "nf_conntrack hashsize=$hs is < max/8 ($((cmax/8))) - long hash chains under load"
    note "Set conntrack hash: echo $((cmax/4)) > /sys/module/nf_conntrack/parameters/hashsize (persist via 'options nf_conntrack hashsize=$((cmax/4))' in /etc/modprobe.d/)"
  else
    msg OK "nf_conntrack hashsize=$hs"
  fi
else
  msg OK "nf_conntrack not loaded"
fi
msg INFO "ip_forward=$(get net.ipv4.ip_forward) rp_filter all=$(get net.ipv4.conf.all.rp_filter) default=$(get net.ipv4.conf.default.rp_filter)"
rpf=$(nstat -az TcpExtIPReversePathFilter 2>/dev/null | awk '/IPReversePathFilter/{print $2}')
if [ -z "$rpf" ]; then
  msg INFO "rp_filter drop counter unavailable (nstat missing)"
elif [ "$rpf" -gt 0 ]; then
  msg WARN "rp_filter has dropped $rpf packets - consider loose mode (2)"
  SUGGEST+=("# [$(printf '%04d' $ID)] WARN: rp_filter is dropping packets" "net.ipv4.conf.all.rp_filter = 2" "net.ipv4.conf.default.rp_filter = 2")
else
  msg OK "rp_filter drops: 0 (keep strict for anti-spoofing)"
fi

section "Network: host socket buffers (host traffic only: storage, migrations, backups, agent)"
tune INFO net.core.rmem_max    ge 16777216 1 "max socket receive buffer"
tune INFO net.core.wmem_max    ge 16777216 1 "max socket send buffer"
tune INFO net.ipv4.tcp_rmem    ge 16777216 3 "TCP receive autotune max"
tune INFO net.ipv4.tcp_wmem    ge 16777216 3 "TCP send autotune max"
tune INFO net.core.somaxconn   ge 4096     1 "listen backlog for host services"
udperr=$(nstat -az UdpRcvbufErrors 2>/dev/null | awk '/UdpRcvbufErrors/{print $2}')
[ -n "$udperr" ] && { [ "$udperr" -gt 0 ] && msg WARN "UdpRcvbufErrors=$udperr (host UDP sockets overflowing)" || msg OK "UdpRcvbufErrors=0"; }

# ---------------------------------------------------------------------------
section "Memory"
tune WARN vm.swappiness       le 1 1 "keep guest memory out of swap"
tune WARN vm.zone_reclaim_mode eq 0 1 "NUMA zone reclaim causes reclaim stalls on hypervisors"
swapused=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print t-f}' /proc/meminfo)
qswap=$(for p in $(pgrep -f 'qemu-(kvm|system)' 2>/dev/null); do awk '/^VmSwap/{print $2}' /proc/$p/status 2>/dev/null; done | awk '{s+=$1}END{print s+0}')
[ "$swapused" -gt 0 ] && msg WARN "Swap in use: $((swapused/1024)) MB total, $((qswap/1024)) MB belongs to qemu (guest stalls on swap-in)" || msg OK "No swap in use"
# Dirty page limits: ratio-based defaults are huge on big-RAM hosts -> long writeback stalls
db=$(get vm.dirty_bytes); dbb=$(get vm.dirty_background_bytes)
dr=$(get vm.dirty_ratio); dbr=$(get vm.dirty_background_ratio)
if [ "${db:-0}" -gt 0 ]; then dmb=$((db/1048576)); else dmb=$((memkb*dr/100/1024)); fi
if [ "${dbb:-0}" -gt 0 ]; then bmb=$((dbb/1048576)); else bmb=$((memkb*dbr/100/1024)); fi
if [ $dmb -gt 8192 ] || [ $bmb -gt 2048 ]; then
  msg WARN "Dirty limits ~${dmb} MB (dirty) / ~${bmb} MB (background) - large flushes can stall I/O (matters for cache=writeback/file-backed disks)"
  SUGGEST+=("# [$(printf '%04d' $ID)] WARN: cap dirty page cache on big-RAM host" "vm.dirty_background_bytes = 1073741824" "vm.dirty_bytes = 4294967296")
else
  msg OK "Dirty limits ~${dmb} MB / ~${bmb} MB background"
fi
mfk=$(get vm.min_free_kbytes)
msg INFO "vm.min_free_kbytes=$mfk ($((mfk/1024)) MB, $(awk -v a="$mfk" -v b="$memkb" 'BEGIN{printf "%.2f", a*100/b}')% of RAM) - raise only if 'page allocation failure' appears in dmesg"
tune INFO vm.max_map_count ge 262144 1 "memory map areas per process (large guests)"
msg INFO "vm.overcommit_memory=$(get vm.overcommit_memory) kernel.numa_balancing=$(get kernel.numa_balancing)"

section "Memory: hugepages / THP / KSM (not sysctl)"
thp=$(sel "$(rd /sys/kernel/mm/transparent_hugepage/enabled)")
thpd=$(sel "$(rd /sys/kernel/mm/transparent_hugepage/defrag)")
case $thp in
  always|madvise) msg OK "THP enabled=$thp (qemu uses madvise)";;
  never) msg WARN "THP enabled=never - guests lose hugepage backing (TLB overhead)"; note "THP: set transparent_hugepage=madvise on kernel cmdline or via tuned";;
  *) msg INFO "THP enabled=$thp";;
esac
case $thpd in
  always) msg WARN "THP defrag=always - direct compaction can stall qemu threads (latency spikes)"; note "THP defrag: echo madvise > /sys/kernel/mm/transparent_hugepage/defrag (persist via tuned or rc)";;
  "") ;;
  *) msg OK "THP defrag=$thpd";;
esac
msg INFO "Static hugepages: $(awk '/HugePages_Total/{t=$2}/HugePages_Free/{f=$2}END{print t" total, "f" free"}' /proc/meminfo)"
ksm=$(rd /sys/kernel/mm/ksm/run)
if [ "$ksm" = "1" ]; then
  msg INFO "KSM running: pages_sharing=$(rd /sys/kernel/mm/ksm/pages_sharing) - costs CPU (ksmd); unnecessary with lots of free RAM"
else
  msg OK "KSM not running"
fi

# ---------------------------------------------------------------------------
section "Filesystem / process limits"
tune WARN fs.file-max                     ge 1000000 1 "system-wide file handles"
tune WARN fs.nr_open                      ge 1048576 1 "per-process fd ceiling"
tune WARN fs.aio-max-nr                   ge 1048576 1 "qemu aio=native contexts"
tune WARN fs.inotify.max_user_watches     ge 524288  1 "libvirt/agents watch many files"
tune WARN fs.inotify.max_user_instances   ge 1024    1 "libvirt/qemu inotify instances"
tune INFO kernel.pid_max                  ge 4194304 1 "qemu threads per VM add up"
msg INFO "fs.aio-nr=$(get fs.aio-nr)  threads in use=$(ps -eLf --no-headers 2>/dev/null | wc -l)"

# ---------------------------------------------------------------------------
section "KVM / virtualization modules"
if [ -d /sys/module/kvm_intel ]; then msg OK "kvm_intel loaded (nested=$(rd /sys/module/kvm_intel/parameters/nested))"
elif [ -d /sys/module/kvm_amd ]; then msg OK "kvm_amd loaded (nested=$(rd /sys/module/kvm_amd/parameters/nested))"
else msg FAIL "No kvm_intel/kvm_amd module loaded"; fi
[ -d /sys/module/vhost_net ] && msg OK "vhost_net loaded (in-kernel virtio-net datapath)" || { msg FAIL "vhost_net NOT loaded - VM networking runs in qemu userspace (slow, drop-prone)"; note "modprobe vhost_net and add it to /etc/modules-load.d/vhost_net.conf"; }
msg INFO "kvm halt_poll_ns=$(rd /sys/module/kvm/parameters/halt_poll_ns)"
grep -Eq 'intel_iommu=on|amd_iommu=on|iommu=pt' /proc/cmdline && msg INFO "IOMMU enabled on cmdline" || msg INFO "IOMMU not set on cmdline (only needed for PCI passthrough/SR-IOV)"

# ---------------------------------------------------------------------------
section "CPU power / scheduling (not sysctl)"
gov=$(rd /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
drv=$(rd /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)
if [ -z "$gov" ]; then
  msg INFO "No cpufreq governor exposed (BIOS-controlled power management) - check BIOS is set to Performance"
elif [ "$gov" = "performance" ]; then
  msg OK "CPU governor=performance (driver=$drv)"
else
  msg WARN "CPU governor=$gov (driver=$drv) - frequency ramp-up adds latency to VM/softirq work"
  note "CPU governor: tuned-adm profile virtual-host (sets performance governor and hypervisor sysctls)"
fi
mc=$(rd /sys/module/intel_idle/parameters/max_cstate)
[ -n "$mc" ] && msg INFO "intel_idle max_cstate=$mc (deep C-states add wake-up latency)"
tp=$(tuned-adm active 2>/dev/null | sed 's/.*: //')
if [ -z "$tp" ]; then msg INFO "tuned not installed/active"
elif [ "$tp" = "virtual-host" ]; then msg OK "tuned profile=virtual-host"
else msg WARN "tuned profile=$tp - 'virtual-host' is the RHEL profile for KVM hosts"; note "tuned-adm profile virtual-host  (review what it sets first: /usr/lib/tuned/virtual-host/tuned.conf)"; fi
if systemctl is-active --quiet irqbalance 2>/dev/null; then msg OK "irqbalance active"
else msg WARN "irqbalance not active - NIC interrupts may pile onto few CPUs (unless pinned manually)"; fi

# ---------------------------------------------------------------------------
section "Physical NICs (ethtool, not sysctl)"
KLOG=$(journalctl -k --no-pager --since "-7d" 2>/dev/null)
[ -z "$KLOG" ] && KLOG=$(dmesg 2>/dev/null)
if ! command -v ethtool >/dev/null; then
  msg INFO "ethtool not installed - skipping ring/queue checks"
else
  for n in /sys/class/net/*; do
    [ -e "$n/device" ] || continue
    i=$(basename "$n"); [ "$(rd $n/operstate)" = "up" ] || { msg INFO "$i is down - skipped"; continue; }
    drvname=$(ethtool -i "$i" 2>/dev/null | awk '/^driver/{print $2}')
    # Ring sizes: ethtool always prints the maximums block first, current second.
    # Parse by position because newer ethtool versions omit the section headers.
    read -r rm rc < <(ethtool -g "$i" 2>/dev/null | awk '/^RX:/{v[++n]=$2} END{print v[1], v[2]}')
    # RX ring overflow evidence. Counter names vary by driver, so sum the known overflow counters from
    # ethtool -S (per-ring "[N]: name" lines included); if none exist, fall back to the standard sysfs ones.
    # Deliberately excluded: the generic rx_dropped, which mostly counts unknown-protocol/VLAN discards, not overflow.
    read -r ovf ovfnames < <(ethtool -S "$i" 2>/dev/null | awk -F: '
      { name=$0; sub(/^[ \t]*(\[[0-9]+\][ \t]*:)?[ \t]*/, "", name); sub(/:.*/, "", name); gsub(/[ \t]/, "", name)
        val=$NF; gsub(/[^0-9]/, "", val); if (val == "") next
        if (name ~ /^(rx_missed_errors|rx_fifo_errors|rx_over_errors|rx_no_buffer_count|rx_no_dma_resources|rxbds_empty|rx_discards|rx_fw_discards|rx_out_of_buffer|rx_buff_alloc_err|port\.rx_dropped)$/) {
          found=1; s+=val; if (val > 0) seen[name]=1 } }
      END { if (!found) { print "none"; exit } n=""; for (k in seen) n = n (n ? "," : "") k; print s+0, (n ? n : "-") }')
    if [ "$ovf" = "none" ] || [ -z "$ovf" ]; then
      ovf=0; ovfnames=""
      for c in rx_missed_errors rx_fifo_errors rx_over_errors; do
        v=$(rd "$n/statistics/$c"); v=${v:-0}
        [ "$v" -gt 0 ] && ovfnames="${ovfnames:+$ovfnames,}$c"
        ovf=$((ovf + v))
      done
    fi
    [ "$ovfnames" = "-" ] && ovfnames=""
    rxp=$(rd "$n/statistics/rx_packets"); rxp=${rxp:-0}
    opct=$(droppct "$ovf" "$rxp"); olvl=$(droplvl "$opct")
    [ "$ovf" -eq 0 ] && olvl=OK
    ovtxt="overflow=$ovf of $rxp packets (${opct}%)${ovfnames:+ [$ovfnames]}"
    # Preventive baseline: a full RX ring drops silently, so hypervisor NICs should sit at the baseline
    # (RX_RING_TARGET, or the hardware max if lower) even with no overflow yet. Overflow raises the severity.
    ringknown=0; [[ "$rc" =~ ^[0-9]+$ && "$rm" =~ ^[0-9]+$ ]] && ringknown=1
    overflowing=0; case $olvl in WARN|FAIL) overflowing=1;; esac
    resetnote="(link resets on most drivers - maintenance window; persist via NetworkManager ethtool.ring-rx or ifupdown post-up)"
    if [ $ringknown -eq 1 ]; then
      base=$(( rm < RX_RING_TARGET ? rm : RX_RING_TARGET ))
      if [ "$rc" -lt "$base" ]; then
        if [ $overflowing -eq 1 ]; then
          msg "$olvl" "$i RX ring=$rc (baseline $base, max $rm), $ovtxt - ring overflowing; raise now"
        else
          msg WARN "$i RX ring=$rc (baseline $base, max $rm), $ovtxt - below hypervisor baseline; raise preventively (RX overflow drops silently)"
        fi
        note "ethtool -G $i rx $base   $resetnote"
      elif [ $overflowing -eq 1 ]; then
        msg "$olvl" "$i RX ring=$rc (baseline $base, max $rm), $ovtxt - ring already at baseline; CPUs not draining fast enough"
        note "$i RX overflow at baseline ring: spread receive first - queues (ethtool -l $i), IRQ spread (irqbalance, /proc/interrupts), RPS$( [ "$rc" -lt "$rm" ] && echo "; if still overflowing, ethtool -G $i rx $rm $resetnote" )"
      else
        msg OK "$i RX ring=$rc (baseline $base, max $rm), $ovtxt"
      fi
    else
      if [ $overflowing -eq 1 ]; then
        msg "$olvl" "$i RX ring size not reported by driver ($drvname), $ovtxt - NIC dropping on receive"
        note "$i RX overflow: ring not tunable on $drvname; spread RX over CPUs (RPS: /sys/class/net/$i/queues/rx-*/rps_cpus)"
      else
        msg "$( [ "$olvl" = OK ] && echo OK || echo INFO )" "$i RX ring size not reported by driver ($drvname), $ovtxt"
      fi
    fi
    # TX ring: a full TX ring makes packets wait in the qdisc (backpressure), not drop.
    # So size alone is INFO; WARN only on evidence: qdisc requeues >= 0.1% of packets sent, or tx timeouts in the kernel log.
    read -r tm tcur < <(ethtool -g "$i" 2>/dev/null | awk '/^TX:/{v[++n]=$2} END{print v[1], v[2]}')
    read -r qpkts qreq < <(tc -s qdisc show dev "$i" 2>/dev/null | awk '/Sent/{for(k=1;k<=NF;k++){if($k=="pkt")p=$(k-1); if($k=="requeues"){r=$(k+1); gsub(/[^0-9]/,"",r)}} print p+0, r+0; exit}')
    qpkts=${qpkts:-0}; qreq=${qreq:-0}
    reqpct=$(awk -v r="$qreq" -v p="$qpkts" 'BEGIN{ if (p==0) print "0.0000"; else printf "%.4f", r*100/p }')
    txto=$(grep -Eic "NETDEV WATCHDOG: $i|$i.*(tx timeout|transmit (queue )?[0-9]* *timed out)" <<<"$KLOG")
    if [[ "$tcur" =~ ^[0-9]+$ && "$tm" =~ ^[0-9]+$ ]]; then
      msg INFO "$i TX ring=$tcur (max $tm) - info only; a full TX ring queues packets in the qdisc rather than dropping"
    else
      msg INFO "$i TX ring size not reported by driver ($drvname)"
    fi
    txev=""
    awk -v x="$reqpct" 'BEGIN{exit !(x>=0.1)}' && txev="qdisc requeues=$qreq of $qpkts packets (${reqpct}%)"
    [ "${txto:-0}" -gt 0 ] && txev="${txev:+$txev, }$txto tx timeout(s) in kernel log"
    if [ -n "$txev" ]; then
      if [[ "$tcur" =~ ^[0-9]+$ && "$tm" =~ ^[0-9]+$ ]] && [ "$tcur" -lt "$tm" ]; then
        msg WARN "$i TX side is backing up: $txev - a larger TX ring may help"
        note "ethtool -G $i tx $tm   (link resets on most drivers - maintenance window)"
      else
        msg WARN "$i TX side is backing up: $txev - TX ring already at max; check link saturation (sar -n DEV) or driver/firmware"
      fi
    else
      msg OK "$i TX side healthy: requeues=$qreq of $qpkts packets (${reqpct}%), no tx timeouts"
    fi
    # Queues: use Combined when the driver supports it, otherwise separate RX channels (e.g. tg3).
    read -r qm qc qtype < <(ethtool -l "$i" 2>/dev/null | awk '
      /^Combined:/{c[++a]=$2} /^RX:/{r[++b]=$2}
      END{ if (c[1] ~ /^[0-9]+$/ && c[1] > 0) print c[1], c[2], "combined"; else print r[1], r[2], "rx" }')
    if [[ "$qc" =~ ^[0-9]+$ && "$qm" =~ ^[0-9]+$ ]]; then
      if [ "$qc" -lt "$qm" ]; then
        msg WARN "$i $qtype queues=$qc (max $qm) - fewer queues = RX load on fewer CPUs"
        note "ethtool -L $i $qtype $qm   (some drivers reset the link when changed)"
      else
        msg OK "$i $qtype queues=$qc (max $qm)"
      fi
    else
      msg INFO "$i multi-queue not supported/reported by driver ($drvname) - all RX on one queue; RPS can spread it across CPUs"
    fi
    msg INFO "$i MTU=$(rd $n/mtu) speed=$(rd $n/speed)Mb/s driver=$drvname"
  done
fi

# ---------------------------------------------------------------------------
section "Interface TX queues (txqueuelen / tx_dropped)"
# tx_dropped is cumulative since the interface was created (for VM taps: since the VM started).
# On a tap device, host "TX" = toward the guest, so drops there mean the guest didn't drain its queue in time.
# Drop % and levels: droppct/droplvl helpers at the top of the script.
ntap=0; nshort=0; ntapdrop=0; ntapnoise=0; nvdrop=0; prefixes=()
for n in /sys/class/net/*; do
  i=$(basename "$n"); [ "$i" = lo ] && continue
  ql=$(rd "$n/tx_queue_len"); td=$(rd "$n/statistics/tx_dropped"); td=${td:-0}
  tp=$(rd "$n/statistics/tx_packets"); tp=${tp:-0}
  pct=$(droppct "$td" "$tp"); lvl=$(droplvl "$pct")
  qd=$(tc qdisc show dev "$i" 2>/dev/null | awk 'NR==1{print $2}')
  if [ -e "$n/tun_flags" ]; then
    kind=tap; ntap=$((ntap+1))
    [ "${ql:-0}" -lt 1000 ] && nshort=$((nshort+1))
  elif [ -e "$n/device" ]; then
    kind=physical
  else
    kind=virtual
  fi
  case $kind in
    physical)
      if [ "$td" -eq 0 ]; then
        msg OK "$i (physical) qdisc=${qd:-?} txqueuelen=$ql tx_dropped=0 of $tp"
      elif [ "$lvl" = INFO ]; then
        msg INFO "$i (physical) qdisc=${qd:-?} txqueuelen=$ql tx_dropped=$td of $tp (${pct}%) - negligible"
      elif [ "$qd" = "pfifo_fast" ]; then
        msg "$lvl" "$i (physical) tx_dropped=$td of $tp (${pct}%) on pfifo_fast, txqueuelen=$ql - queue too short for bursts"
        note "ip link set dev $i txqueuelen 10000  (or switch qdisc: sysctl net.core.default_qdisc=fq_codel)"
      else
        msg "$lvl" "$i (physical) tx_dropped=$td of $tp (${pct}%) qdisc=${qd:-?} - check: tc -s qdisc show dev $i; ethtool -S $i | grep -i drop"
      fi
      ;;
    tap)
      [ "$td" -eq 0 ] && continue
      if [ "$lvl" = INFO ]; then
        ntapnoise=$((ntapnoise+1))
        msg INFO "$i (VM tap) tx_dropped=$td of $tp (${pct}%) - negligible (likely VM boot/shutdown or guest NIC down)"
      else
        ntapdrop=$((ntapdrop+1))
        p=${i%%[0-9]*}; [[ " ${prefixes[*]} " == *" $p "* ]] || prefixes+=("$p")
        msg "$lvl" "$i (VM tap) tx_dropped=$td of $tp (${pct}%) txqueuelen=$ql - packets INTO the guest dropped; guest not draining fast enough (busy/CPU-starved guest or queue too short)"
      fi
      ;;
    virtual)
      if [ "$td" -gt 0 ]; then
        nvdrop=$((nvdrop+1))
        msg INFO "$i (virtual) tx_dropped=$td of $tp (${pct}%) qdisc=${qd:-?} - drops on a bridge/OVS/tunnel device; usually policy or no-route, not queue length"
      fi
      ;;
  esac
done
msg INFO "VM tap interfaces: $ntap total, $nshort with txqueuelen < 1000, $ntapdrop with significant drops (>= 0.01%), $ntapnoise with negligible drops"
if [ $ntapdrop -gt 0 ]; then
  match=$(printf '%s*|' "${prefixes[@]}"); match=${match%|}
  note "VM tap tx drops: raise queue on new taps via /etc/udev/rules.d/60-txqueuelen.rules: SUBSYSTEM==\"net\", ACTION==\"add\", KERNEL==\"$match\", ATTR{tx_queue_len}=\"5000\"  (existing taps: ip link set dev <tap> txqueuelen 5000). If one guest keeps dropping, check its vCPU load/virtio multiqueue first."
elif [ $ntap -gt 0 ]; then
  msg OK "No VM tap interfaces are dropping packets"
fi

# ---------------------------------------------------------------------------
section "Suggested sysctl file (NOT applied - review before use)"
if [ ${#SUGGEST[@]} -eq 0 ]; then
  msg OK "No sysctl changes suggested"
else
  msg INFO "Save as /etc/sysctl.d/90-hypervisor.conf, check no later-sorting file overrides it, then: sysctl --system"
  printf '%s\n' "${SUGGEST[@]}" | sed 's/^/        /'
fi

section "Non-sysctl suggestions"
if [ ${#NOTES[@]} -eq 0 ]; then msg OK "None"; else for x in "${NOTES[@]}"; do msg INFO "$x"; done; fi

section "Summary"
msg INFO "OK=$NOK WARN=$NWARN FAIL=$NFAIL  (INFO lines are optional/contextual)"