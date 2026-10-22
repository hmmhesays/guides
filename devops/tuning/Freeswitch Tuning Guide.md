# FreeSWITCH Kernel & NIC Tuning Guide

Companion to `freeswitch-tuning-audit.sh`. This guide explains what each check in the audit looks at, why it matters for a FreeSWITCH media server, and what to do when it flags something.

The script only reads kernel, sysctl and NIC state. It never reads FreeSWITCH's configuration or changes anything.

---

## Contents

1. [Running the audit](#1-running-the-audit)
2. [Why a media server is different](#2-why-a-media-server-is-different)
3. [The packet path (read this first)](#3-the-packet-path)
4. [UDP socket buffers](#4-udp-socket-buffers)
5. [Packet processing](#5-packet-processing)
6. [Port ranges](#6-port-ranges)
7. [Connection tracking and the SIP ALG](#7-connection-tracking-and-the-sip-alg)
8. [Memory, threads and file handles](#8-memory-threads-and-file-handles)
9. [Timing](#9-timing)
10. [CPU](#10-cpu)
11. [Physical NICs: rings, queues, txqueuelen](#11-physical-nics)
12. [Drop counters and the live sample](#12-drop-counters-and-the-live-sample)
13. [Kernel log patterns](#13-kernel-log-patterns)
14. [Applying and persisting changes](#14-applying-and-persisting-changes)
15. [Triage: from symptom to check](#15-triage-from-symptom-to-check)
16. [Quick reference](#16-quick-reference)

---

## 1. Running the audit

```bash
sudo bash freeswitch-tuning-audit.sh | tee fs-tuning-report.txt
SAMPLE=10 sudo bash freeswitch-tuning-audit.sh     # longer live sample
SAMPLE=0  sudo bash freeswitch-tuning-audit.sh     # skip the live sample
```

Run it as root. Without root, `/proc/timer_list`, the kernel log and some counters can't be read, and those checks fall back to INFO.

### Reading the output

Every line has an incrementing ID, so you can refer to findings later (for example "see [0045]").

| Level  | Meaning                                                                 |
|--------|-------------------------------------------------------------------------|
| `OK`   | Meets the recommendation.                                               |
| `INFO` | Context, or a soft recommendation. Not counted as a problem.            |
| `WARN` | Below the recommendation, or evidence of past trouble.                  |
| `FAIL` | Actively harmful setting, or drops happening during the live sample.    |
| `NOTE` | A remedy that isn't a sysctl (ethtool, iptables, cmdline, etc.).        |

At the end the script prints:

* **A suggested `/etc/sysctl.d/90-freeswitch.conf`.** Every line carries the ID and reason of the finding that produced it. Review it before applying; it's a starting point, not a prescription.
* **NOTE lines** for fixes that live outside sysctl.

> **Recommendations are targets for a busy box** (hundreds to thousands of concurrent channels). A small PBX with 20 calls will show WARNs it can safely ignore. Weigh every WARN against the evidence sections (12 and 13): a setting below target with zero drops is a low priority.

---

## 2. Why a media server is different

A web server moves fewer, larger packets over TCP, and TCP retransmits anything lost. A FreeSWITCH box moves **huge numbers of tiny UDP packets on a strict clock**, and nothing retransmits them.

```
  One G.711 call leg, 20 ms ptime
  --------------------------------
  50 packets/s each way, ~214 bytes each on the wire

  1,000 bridged calls = 2,000 legs
    x 50 pps x 2 directions
    = 200,000 packets/s     (at only ~340 Mbit/s)
```

That shapes everything in this guide:

* **Packet rate, not bandwidth, is the load.** Per-packet costs (interrupts, softirq budget, per-CPU backlogs) run out long before the link does.
* **A dropped RTP packet is gone.** The caller hears a click or a gap. Jitter buffers hide small losses but not bursts.
* **Late is the same as lost.** A packet that arrives after the jitter buffer has played out its slot is discarded. Latency spikes (swap, CPU frequency ramps, deep C-states, steal time) show up as audio problems even with zero drops.
* **Thousands of sockets and threads.** Each call leg holds RTP and RTCP sockets plus timers and threads, so file-handle, thread and memory-map limits matter.

---

## 3. The packet path

Almost every check in the audit is a buffer, a limit or a counter somewhere on this path. When you see a drop counter, find it here to know which setting to look at.

### Receive (inbound RTP/SIP)

```
  wire
   |
   v
+-----------------------+   ethtool -g  (RX ring size)
|  NIC RX ring          |   overflow -> rx_missed_errors / rx_fifo_errors
|  (descriptors in RAM) |              (ethtool -S, /sys/.../statistics)
+-----------------------+
   |  IRQ -> NAPI poll (softirq)
   v
+-----------------------+   net.core.netdev_budget / netdev_budget_usecs
|  softirq processing   |   ran out of budget with work left -> time_squeeze
+-----------------------+
   |  (only when RPS/RFS, virtual devices or tunnels hand packets between CPUs)
   v
+-----------------------+   net.core.netdev_max_backlog  (per CPU)
|  per-CPU backlog      |   overflow -> softnet "dropped" (/proc/net/softnet_stat)
+-----------------------+
   |
   v
+-----------------------+   rp_filter, iptables/nftables
|  IP + netfilter       |   nf_conntrack_max -> "nf_conntrack: table full"
|  (conntrack)          |   SIP ALG (nf_conntrack_sip) rewrites here
+-----------------------+
   |
   v
+-----------------------+   rmem_default / rmem_max / udp_mem
|  UDP socket rcvbuf    |   overflow -> UdpRcvbufErrors (/proc/net/snmp)
+-----------------------+
   |  recvfrom()
   v
  FreeSWITCH media / SIP thread
```

### Transmit (outbound RTP/SIP)

```
  FreeSWITCH media / SIP thread
   |  sendto()
   v
+-----------------------+   wmem_default / wmem_max
|  UDP socket sndbuf    |   full -> UdpSndbufErrors
+-----------------------+
   |
   v
+-----------------------+
|  IP + netfilter       |
+-----------------------+
   |
   v
+-----------------------+   txqueuelen (pfifo_fast) or the qdisc's own limit
|  qdisc (egress queue) |   overflow -> tx_dropped, tc -s qdisc "dropped"
|  pfifo_fast/fq_codel  |   net.core.default_qdisc
+-----------------------+
   |
   v
+-----------------------+   ethtool -g  (TX ring size)
|  NIC TX ring          |   driver-specific counters in ethtool -S
+-----------------------+
   |
   v
  wire
```

**Rule of thumb:** a drop tells you which buffer was too small *or* which consumer was too slow. Raising the buffer helps short bursts. If the consumer (a CPU, a thread, the guest) is persistently slow, a bigger buffer just delays the drop and adds latency. Always ask "is this a burst or a sustained shortfall?" before raising a limit.

---

## 4. UDP socket buffers

Section header in the output: **Network: UDP socket buffers (SIP + RTP)**

### What it checks

| Key                     | Target       | Level |
|-------------------------|--------------|-------|
| `net.core.rmem_max`     | >= 16777216  | WARN  |
| `net.core.wmem_max`     | >= 16777216  | WARN  |
| `net.core.rmem_default` | >= 1048576   | WARN  |
| `net.core.wmem_default` | >= 524288    | INFO  |
| `net.ipv4.udp_rmem_min` | >= 16384     | INFO  |
| `net.ipv4.udp_wmem_min` | >= 16384     | INFO  |
| `net.ipv4.udp_mem`      | reported     | INFO  |

### How these fit together

```
  per socket                                   all UDP sockets together
  ----------                                   ------------------------
  udp_rmem_min  <=  rmem_default  <=  rmem_max      udp_mem (pages)
     floor            what you get     ceiling for    min | pressure | max
     under            if the app       setsockopt     ----+----------+---->
     pressure         doesn't ask      (SO_RCVBUF)        squeeze   refuse
```

* **`rmem_max` / `wmem_max`** are ceilings. An application that calls `setsockopt(SO_RCVBUF)` is silently capped here. Raising the ceiling costs nothing until something asks for it.
* **`rmem_default` / `wmem_default`** are what a socket gets if the application never asks. Many media and SIP sockets never ask, so the default is the effective buffer. The stock 212992 bytes is fine for one quiet RTP stream, but the SIP listening socket takes every REGISTER and INVITE on the profile. A registration storm after a network blip, or a brief CPU stall, can overflow it.
* **`udp_rmem_min` / `udp_wmem_min`** guarantee each socket a minimum when the system is under UDP memory pressure.
* **`udp_mem`** is three numbers in **pages** (usually 4 KB), not bytes: below `min` no pressure, above `pressure` the kernel starts trimming buffers toward the minimum, above `max` it refuses to queue more. The kernel sizes it from RAM at boot. The script converts the max to MB for you.

> **Memory cost.** A buffer limit isn't an allocation. A 1 MB `rmem_default` only uses memory when a socket actually falls behind. Thousands of idle RTP sockets with 1 MB limits use almost nothing; `udp_mem` caps the worst case for all of them together.

### Remedies

* Apply the suggested values from the generated sysctl file.
* Touch `udp_mem` only if `MemErrors` is non-zero (section 12). That means the global limit was hit, which at these sizes usually means a consumer is badly stuck rather than a tuning problem.
* If `UdpRcvbufErrors` keeps growing after raising buffers, the reader is too slow: look at CPU (section 10), steal (section 12) and the FreeSWITCH process itself.

---

## 5. Packet processing

Section header: **Network: packet processing**

| Key                            | Target   | Level | Why                                                        |
|--------------------------------|----------|-------|------------------------------------------------------------|
| `net.core.netdev_max_backlog`  | >= 16384 | WARN  | Per-CPU backlog; overflow = softnet drops                  |
| `net.core.netdev_budget`       | >= 600   | INFO  | Packets per softirq run                                    |
| `net.core.somaxconn`           | >= 4096  | INFO  | Listen backlog for SIP TCP/TLS, WSS, ESL                   |
| `net.ipv4.tcp_max_syn_backlog` | >= 4096  | INFO  | Half-open TCP connections during reconnect storms          |
| `net.ipv4.tcp_keepalive_time`  | <= 600   | INFO  | Detect dead SIP TCP/TLS peers through NAT                  |
| `net.ipv4.conf.all.rp_filter`  | reported | INFO  | Strict mode can drop RTP on multi-homed hosts              |

### netdev_max_backlog and netdev_budget

```
      CPU 0                 CPU 1                 CPU 2
  +-----------+         +-----------+         +-----------+
  | backlog   |         | backlog   |         | backlog   |
  | [||||||  ]|         | [||||||||]| <- full | [||      ]|
  +-----------+         +-----------+         +-----------+
       |                     |  next packet          |
       v                     v  is DROPPED           v
  softirq takes up to netdev_budget packets per run (shared across devices)
```

* **The backlog is per CPU.** One hot CPU can drop while the others idle. That's why the script lists softnet drops per row (section 12).
* **When the backlog is used:** with a plain physical NIC and no RPS, packets go from the RX ring straight into processing and the backlog isn't involved. It *is* used when RPS/RFS steer packets to another CPU, and for virtual devices (veth, tun/tap, some tunnels and bridges). On a bare-metal box with a modern multi-queue NIC, softnet drops are less common; in containers or with RPS, they're the first place to look.
* **`netdev_budget`** caps how many packets one softirq run processes before yielding. If it runs out with packets still waiting, softnet's `time_squeeze` column goes up. A rising `time_squeeze` alone isn't a drop, but combined with backlog drops it means the CPU can't keep up.

### TCP settings

These only matter if you run SIP over TCP, TLS or WebSockets, or use ESL heavily.

* **`somaxconn` / `tcp_max_syn_backlog`:** after an outage, every TCP/TLS phone reconnects at once. A short accept queue drops SYNs and phones back off for seconds or minutes.
* **`tcp_keepalive_time`:** NAT routers usually forget idle TCP mappings within minutes; the 2-hour default is far too long to notice a dead peer. This setting only affects sockets that enable `SO_KEEPALIVE`. Many SIP stacks also send their own keepalives (CRLF pings, OPTIONS), which are usually the better tool. Lowering the kernel value is cheap insurance.

### rp_filter

Reverse-path filtering drops packets that arrive on an interface the kernel wouldn't use to reply to their source.

```
                 +--------------------+
  carrier A ---->| eth0  10.0.0.5     |    RTP from carrier B arrives on eth1,
                 |                    |    but the route back to B is via eth0.
  carrier B ---->| eth1  192.0.2.5    |    rp_filter=1 (strict): DROPPED
                 +--------------------+    rp_filter=2 (loose):  accepted
```

* `0` off, `1` strict, `2` loose. The kernel uses the **higher** of `conf.all` and the per-interface value.
* Single-homed box: strict is fine and blocks spoofed traffic. Keep it.
* Multi-homed box (separate carrier/LAN/public interfaces, asymmetric routing): check `nstat -az TcpExtIPReversePathFilter`. If it's climbing, set `net.ipv4.conf.all.rp_filter = 2`.

---

## 6. Port ranges

Section header: **Port ranges**

The script reports `net.ipv4.ip_local_port_range` and `net.ipv4.ip_local_reserved_ports`, and adds a NOTE. It doesn't know your RTP range, so the comparison is yours to make.

```
  0        1024           16384                32768                     60999   65535
  |--------|----------------|--------------------|-------------------------|-------|
           |                |<--- typical RTP --->|<--- default ephemeral -->|
           |                |     range           |     range                |
                                            touch at 32768 (harmless)

  If someone widens the ephemeral range to 1024-65535:
           |<===================== ephemeral range ====================================>|
                            |<--- RTP range ----->|
                             overlap: outbound connections, DNS lookups, DB clients
                             can grab ports FreeSWITCH wants for media
```

* The **ephemeral range** is where the kernel picks source ports for outbound connections and unbound UDP sends (DNS lookups, database clients, HTTP calls, ESL clients).
* If it overlaps your **RTP range**, some media ports will occasionally be busy. FreeSWITCH skips a busy port and tries the next one, so the effect is usually just log noise and a smaller usable pool, but under load it can mean failed media allocation.

### Remedies

Reserve the RTP range so the kernel never hands it out automatically. Applications can still bind those ports explicitly, which is exactly what FreeSWITCH does:

```ini
# /etc/sysctl.d/90-freeswitch.conf
net.ipv4.ip_local_reserved_ports = 16384-32768
```

Or move the ephemeral range away from it. Reserving is safer because it doesn't shrink the ephemeral pool for everything else.

Also make sure your SIP (5060/5061/5080/5081), WSS (7443) and ESL (8021) ports aren't inside the ephemeral range if it's been widened.

---

## 7. Connection tracking and the SIP ALG

Section header: **Connection tracking (firewall state for SIP/RTP flows)**

| Check                                         | Target    | Level |
|-----------------------------------------------|-----------|-------|
| `nf_conntrack_count` / `nf_conntrack_max`     | < 80% full| FAIL if over |
| `net.netfilter.nf_conntrack_max`              | >= 262144 | WARN  |
| `net.netfilter.nf_conntrack_udp_timeout_stream`| >= 120   | INFO  |
| `nf_conntrack_sip` / `nf_nat_sip` loaded      | not loaded| FAIL  |

If conntrack isn't loaded (no stateful firewall), the script says so and skips the table checks.

### Why the table fills up

Every UDP 5-tuple is its own conntrack entry.

```
  One bridged call (A-leg + B-leg), audio only:

    phone <--RTP-->  FreeSWITCH  <--RTP--> carrier      2 entries
    phone <--RTCP--> FreeSWITCH  <--RTCP-> carrier      2 entries
    + SIP signalling (often shared per peer)            ~0-2 entries
                                                        -----------
                                                        ~4-6 per call
  Video doubles the media entries.
  Entries linger after hangup until their UDP timeout expires.
```

When the table is full, the kernel **silently drops new flows** and logs `nf_conntrack: table full, dropping packet`. Calls set up fine but have no audio, or new calls fail entirely.

* **`nf_conntrack_max`:** raise it to comfortably above your peak. Each entry costs roughly 300 bytes of kernel memory, so 262144 entries is under 100 MB. Raise `nf_conntrack_buckets` (via the `hashsize` module parameter) alongside it; a common ratio is max = 4 x buckets.
* **`udp_timeout_stream`:** how long an established UDP flow survives without packets. A call on hold with no RTP, or a codec using silence suppression, can go quiet. If the entry expires, the next packet may hit a firewall rule meant for new traffic. 120 s is the usual minimum; 180 s is safer if you use silence suppression.

### The SIP ALG (FAIL)

`nf_conntrack_sip` and `nf_nat_sip` are kernel "application layer gateways" that parse SIP and rewrite addresses in SIP headers and SDP bodies, and open "expected" conntrack entries for RTP.

On a router in front of simple phones this was once helpful. **On a SIP server it is almost always harmful.** FreeSWITCH already handles NAT itself, and a second party rewriting SDP causes one-way audio, failed re-INVITEs, broken transfers and hold, and TLS (which the ALG can't read) behaving differently from UDP.

Since kernel 4.7 the helper isn't attached to traffic automatically (`nf_conntrack_helper=0` by default); it only acts if a firewall rule assigns it (`-j CT --helper sip`). A loaded module is still worth removing so nobody turns it on by accident. To see whether it's active on flows:

```bash
conntrack -L 2>/dev/null | grep -c 'helper=sip'
iptables-save | grep -i 'helper'
```

Remove and blacklist it:

```bash
modprobe -r nf_nat_sip nf_conntrack_sip
cat > /etc/modprobe.d/no-sip-alg.conf <<'EOF'
blacklist nf_nat_sip
blacklist nf_conntrack_sip
EOF
```

Also check your **edge router or cloud firewall**. Many consumer and SMB routers enable a SIP ALG by default, and it causes the same problems even though it's not on this box.

### Not tracking RTP at all

On a dedicated media server you can exempt the RTP range from conntrack entirely. That removes the table-size and timeout concerns for media and saves CPU on every packet.

```bash
# replace 16384:32768 with your RTP range
iptables -t raw -A PREROUTING -p udp --dport 16384:32768 -j CT --notrack
iptables -t raw -A OUTPUT     -p udp --sport 16384:32768 -j CT --notrack
# untracked packets skip ESTABLISHED,RELATED, so allow them explicitly:
iptables -A INPUT -p udp --dport 16384:32768 -j ACCEPT
```

nftables equivalent: a `notrack` statement in a `raw`-priority prerouting/output chain.

---

## 8. Memory, threads and file handles

Section header: **Memory, threads and file handles**

| Key                  | Target    | Level | Why                                              |
|----------------------|-----------|-------|--------------------------------------------------|
| `vm.swappiness`      | <= 10     | WARN  | Swapped-out pages stall media threads            |
| `vm.max_map_count`   | >= 262144 | WARN  | Each thread stack is a memory mapping            |
| `kernel.threads-max` | >= 32768  | WARN  | System-wide thread cap                           |
| `kernel.pid_max`     | >= 131072 | INFO  | Threads use PIDs too                             |
| `fs.file-max`        | >= 2097152| INFO  | System-wide open file cap                        |
| `fs.nr_open`         | >= 1048576| INFO  | Ceiling for any process's open-file limit        |
| Transparent hugepages| madvise or never | INFO if `always` | Compaction stalls          |

### Swap

A media thread that touches a swapped-out page stops until the page is read back from disk: tens of milliseconds on SSD, far more on spinning disk. At 20 ms ptime, that's one or more lost packets per stall, across every call that thread handles.

* `vm.swappiness = 10` (or 1) tells the kernel to strongly prefer dropping file cache over swapping process memory.
* It doesn't pull back pages already in swap. To do that (with enough free RAM, in a quiet window): `swapoff -a && swapon -a`.
* Some admins run media servers with no swap at all. That's a valid choice, but then running out of memory means the OOM killer instead of slowness. Size RAM accordingly.

### Threads, maps and PIDs

FreeSWITCH uses many threads (per session, per media timer, per module). Each thread costs:

```
  one thread
  +--------------------+
  | stack mapping      |  -> counts toward vm.max_map_count  (per process)
  | guard page mapping |  -> counts toward vm.max_map_count
  | task struct        |  -> counts toward kernel.threads-max (system)
  | PID/TID            |  -> counts toward kernel.pid_max    (system)
  +--------------------+
```

* **`vm.max_map_count`** defaults to 65530 mappings per process. With two mappings per thread plus the libraries and heap, a few tens of thousands of threads hits it, and thread creation fails with `ENOMEM` even with free RAM. Raising it to 262144 is cheap.
* **`kernel.threads-max`** is sized automatically from RAM at boot; it's usually fine on servers.
* **`kernel.pid_max`**: modern systemd distributions raise this to 4194304 automatically; older ones leave 32768, which a busy box can exhaust.

### File handles

* **`fs.file-max`** is the system-wide total. Modern kernels set it very high.
* **`fs.nr_open`** is the highest value any process's open-file limit (`ulimit -n`, systemd `LimitNOFILE=`) can be set to. If you raise a service's limit above `nr_open`, the change silently fails.

### Transparent hugepages

With THP set to `always`, the kernel tries to back memory with 2 MB pages and runs background compaction (`khugepaged`) to create them. Compaction can stall a thread for milliseconds at random. `madvise` gives hugepages only to applications that ask, which is the safer default for latency-sensitive services.

```bash
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled   # now
# persist: add transparent_hugepage=madvise to the kernel cmdline
```

---

## 9. Timing

Section header: **Timing (RTP is paced by kernel timers)**

FreeSWITCH sends media on a clock: every 20 ms (or 10/30 ms) per stream. If the kernel's timers are coarse or jittery, packets leave in uneven bursts and the far end's jitter buffer has to work harder.

```
  ideal 20 ms pacing:
  |----|----|----|----|----|----|----|----|
  ^    ^    ^    ^    ^    ^    ^    ^    ^

  jittery timer / slow clocksource / CPU waking from deep sleep:
  |------|--|-----|---|------|-|----|-----|
  ^      ^  ^     ^   ^      ^ ^    ^     ^
         bursts and gaps -> far-end jitter buffer grows or drops
```

| Check                       | Good                          | Level if bad |
|-----------------------------|-------------------------------|--------------|
| Clocksource                 | `tsc`, `kvm-clock`, `arch_sys_counter` | WARN |
| High-resolution timers      | active (`hres_active: 1`)     | FAIL         |
| `CONFIG_HZ`                 | reported                      | INFO         |
| NTP synchronised            | yes                           | WARN         |

* **Clocksource:** every timestamp read goes through it. `tsc` is fastest on modern x86; `kvm-clock` is correct inside KVM guests; `arch_sys_counter` on ARM64. `hpet` and `acpi_pm` are much slower to read and usually mean the kernel decided the TSC was unreliable (check the kernel log for "clocksource ... unstable", section 13). Causes include old BIOS, power-saving settings, or VM migration.
* **High-resolution timers** let the kernel fire timers at microsecond precision instead of rounding to the next scheduler tick. They're on by default on any modern kernel; off means a very unusual kernel build.
* **`CONFIG_HZ`** is the scheduler tick rate (100, 250, 300 or 1000). With high-resolution timers active it matters little for timer precision. It's reported for reference.
* **NTP** doesn't affect media pacing, but a drifting clock skews CDR timestamps, breaks TLS certificate checks, and can break digest authentication nonces.

---

## 10. CPU

Section header: **CPU**

| Check                   | Recommended                  | Level |
|-------------------------|------------------------------|-------|
| Frequency governor      | `performance`                | WARN otherwise |
| C-state limits          | reported                     | INFO  |
| irqbalance              | reported                     | INFO  |
| `kernel.sched_rt_runtime_us` | reported                | INFO  |

### Frequency governor and C-states

Power-saving makes CPUs slow down and sleep when idle. Media load is idle most of each millisecond and then wakes up on a timer, which is exactly the pattern power-saving penalises.

```
  load:   _|‾|____|‾|____|‾|____|‾|____      short bursts every few ms
  freq:   ___/‾‾\____/‾‾\____/‾‾\_____       ramps up after the burst started
  wake:   deep C-state exit = 10-200 µs added to every wake-up
```

* **Governor:** `performance` keeps clocks high. With `intel_pstate`, the `powersave` governor is actually dynamic and not as bad as the name suggests, but `performance` still has the lowest latency.
  ```bash
  cpupower frequency-set -g performance
  # or: tuned-adm profile latency-performance  (also handles C-states)
  ```
  Also check the BIOS/UEFI power profile ("Max Performance" or "OS Control"). A firmware-controlled profile can override the OS.
* **C-states:** limiting them (`intel_idle.max_cstate=1 processor.max_cstate=1` on the cmdline, or the `tuned` profile above) removes wake-up latency at the cost of power and heat. Do this only if you have measured jitter. Most boxes don't need it.
* In a VM, there's usually no cpufreq governor to see; the hypervisor controls the real clocks.

### irqbalance

Spreads NIC and other interrupts across CPUs. Keep it running unless you pin IRQs to specific CPUs by hand (in which case disable it, or it will undo your pinning).

### sched_rt_runtime_us

FreeSWITCH can run media threads with realtime scheduling. `kernel.sched_rt_runtime_us` (default 950000) lets realtime threads use at most that many microseconds of each second, leaving the rest for everything else so a runaway realtime thread can't freeze the box. `-1` removes the safety net; leave it at the default unless you have a specific reason.

---

## 11. Physical NICs

Section header: **Physical NICs (rings, queues, txqueuelen, drops)**

For each interface backed by a device (physical NICs, and virtio NICs inside VMs), the script reports two lines:

```
eno1: speed 10000Mb/s  rings cur/max: rx 512/4096 tx 512/4096  combined queues 8/8  rx missed/fifo since boot 0  rx_dropped 0
eno1: qdisc mq  txqueuelen 1000  tx_dropped 0 of 9581273 packets
```

It also reports `net.core.default_qdisc` once at the top of the section.

### RX and TX rings

The ring is a circle of descriptors shared between NIC and driver. The NIC writes incoming packets into free slots; the kernel frees slots as it processes them.

```
              NIC writes here
                    |
                    v
          +---+---+---+---+---+---+---+---+
          | x | x | x |   |   |   | x | x |    x = packet waiting
          +---+---+---+---+---+---+---+---+
                                ^
                                |
                     kernel (NAPI) reads here

  Ring full -> NIC has nowhere to put the next packet -> rx_missed_errors
```

* A larger RX ring absorbs longer bursts (or longer softirq delays) before the NIC drops.
* It doesn't make processing faster, and a full large ring adds latency. Raise it when you see `rx_missed_errors` / `rx_fifo_errors`, not by default.
* The script counts only `rx_missed_errors` + `rx_fifo_errors` as ring overflows. It suggests raising the ring when there are overflows **and** the ring is below its maximum; if the ring is already at max, it points you at queues and IRQ spread instead, because the CPU side is the bottleneck.

```bash
ethtool -g eno1                 # current and max
ethtool -G eno1 rx 4096         # raise RX only (may briefly reset the link)
ethtool -S eno1 | grep -iE 'drop|miss|fifo|no_buf'
```

`rx_dropped` in `/sys/class/net/<nic>/statistics` also counts packets the kernel discarded for reasons unrelated to buffer space (unknown protocol, VLAN not configured, and so on). If `rx_missed_errors` and `rx_fifo_errors` are zero and only `rx_dropped` grows, it's usually not a ring problem.

#### The TX ring: leave it at the default

The TX ring works differently, and raising it is rarely useful on a voice server.

```
  qdisc (fq_codel)              TX ring (plain FIFO)            wire
  +------------------+         +---+---+---+---+---+---+
  | flow A: RTP      |  --->   | B | B | B | B | A | B |  --->
  | flow B: backup   |         +---+---+---+---+---+---+
  | per-flow fair,   |           RTP packet "A" waits behind
  | short delays     |           every bulk packet ahead of it
  +------------------+
        ^
        |  ring full -> driver pauses the queue -> packets wait HERE (no loss)
```

* **A full TX ring usually doesn't drop.** The driver pauses the queue and packets wait in the qdisc. TX loss normally shows up as qdisc drops (`tc -s qdisc`), not in the ring.
* **A bigger TX ring moves queueing from a smart queue to a dumb one.** In the qdisc, `fq_codel` keeps RTP apart from bulk traffic. In the ring, RTP waits behind everything ahead of it. With 1500-byte packets, 4096 descriptors is about 49 ms of queue at 1 Gbit/s (about 5 ms at 10 Gbit/s) when bulk traffic shares the link.
* **Byte queue limits (BQL) often make it moot.** Most modern drivers (igb, ixgbe, i40e, mlx5, bnxt) cap the bytes in flight on the TX ring regardless of its size.
* **A rising `tx_restart_queue` or `tx_busy` in `ethtool -S` is not loss.** It's the ring pausing the queue as designed.

Raise the TX ring only when `tx_dropped` is climbing, the qdisc shows no drops (so the loss is in the driver), and the driver's TX counters point at the ring. That's the only case where the script adds a NOTE about it. The next part explains how to tell.

Changing either ring with `ethtool -G` reinitialises the NIC on many drivers, which drops the link for a second or two and cuts audio on live calls. Do it in a maintenance window.

### Combined queues (RSS)

Modern NICs have several RX/TX queue pairs, each with its own ring and interrupt, so different CPUs handle different flows. The NIC picks a queue by hashing each packet's addresses and ports.

```
                        +--> queue 0 --> IRQ --> CPU 0
  incoming   hash(src,  +--> queue 1 --> IRQ --> CPU 1
  packets -> dst, ports)+--> queue 2 --> IRQ --> CPU 2
                        +--> queue 3 --> IRQ --> CPU 3
```

* `ethtool -l <nic>` shows current vs maximum. If current is below max and you have the CPUs, raise it: `ethtool -L <nic> combined <n>`.
* **UDP hashing caveat:** some drivers hash UDP on IP addresses only by default. All RTP from one carrier IP then lands on one queue and one CPU. Check and fix:
  ```bash
  ethtool -n eno1 rx-flow-hash udp4      # want: IP SA, IP DA, L4 bytes 0&1, L4 bytes 2&3
  ethtool -N eno1 rx-flow-hash udp4 sdfn  # include source and destination ports
  ```

### txqueuelen and the qdisc

Linux queues only on the **transmit** side, in the qdisc (queueing discipline) in front of the TX ring. There's no `rxqueuelen`; the RX equivalents are the RX ring and `netdev_max_backlog`.

```
  socket sndbuf --> qdisc --> TX ring --> wire
                    ^^^^^
                    pfifo_fast: one FIFO, length = txqueuelen
                    mq:         one child qdisc per hardware TX queue
                                (child type = net.core.default_qdisc)
                    fq_codel:   per-flow queues with its own packet limit;
                                drops/marks packets that sit too long
```

* **`txqueuelen`** (default 1000) is the queue length **for `pfifo_fast`**. Qdiscs like `fq_codel` have their own `limit` and largely ignore it.
* **`tx_dropped`** on a physical NIC means the qdisc or driver discarded outbound packets.
* RTP is a steady stream of small packets, so egress queues rarely fill. TX drops usually point to a burst source sharing the link (backups, recordings uploads, a big file transfer) or a link running near capacity.

### Is the TX loss in the qdisc or the driver?

The interface's `tx_dropped` and the qdisc's own `dropped` are counted in different places, so comparing them over the same window tells you where packets are lost:

```
  sendto()
     |
     v
  qdisc  ----------- drop here --> tc -s qdisc        "dropped N"
     |
     v
  driver / TX ring - drop here --> ip -s link         TX "dropped"
     |                             ethtool -S         driver counters
     v
   wire
```

Since-boot totals can't be compared directly: the qdisc's counter resets whenever the qdisc is replaced, and both may be months old. Compare **deltas over the same window during load**. The script's live sample does this per NIC (section 12). To do it by hand:

```bash
NIC=eno1
snap() {
  dev=$(cat /sys/class/net/$NIC/statistics/tx_dropped)
  q=$(tc -s qdisc show dev $NIC | awk '/^qdisc/{r=($0 ~ / root( |$)/)}
        r && /dropped/{gsub(/[(),]/,""); for(i=1;i<=NF;i++) if($i=="dropped") s+=$(i+1)}
        END{print s+0}')
  echo "$dev $q"
}
read d1 q1 <<<"$(snap)"; sleep 30; read d2 q2 <<<"$(snap)"
echo "interface tx_dropped +$((d2-d1))   qdisc dropped +$((q2-q1))"
```

Only the **root** qdisc is read: an `mq` root already reports the sum of its per-queue children, so adding the children would double-count.

| Interface `tx_dropped` | Qdisc `dropped`  | Where the loss is |
|------------------------|------------------|-------------------|
| grows                  | grows            | **Qdisc.** Fix the qdisc or the link, not the TX ring. |
| grows                  | flat             | **Driver or core.** Read the driver counters (below). |
| flat                   | grows            | Qdisc drops not mirrored to the interface counter (varies by kernel and driver). Still a qdisc problem. |

**Qdisc drops.** In `tc -s qdisc`, an `fq_codel` child with `drop_overlimit` rising has hit its hard packet limit. Ordinary CoDel drops mean packets sat in the queue too long, i.e. the link or one flow is genuinely congested; find the bulk sender. On `pfifo_fast`, the queue length (`txqueuelen`) was too short for a burst.

**Driver drops.** See which driver counters moved:

```bash
ethtool -S $NIC | grep -i tx | grep -v ': 0$'
ip -s -s link show $NIC                 # TX errors: aborted, fifo, carrier, ...
cat /sys/class/net/$NIC/carrier_changes
```

Counter names vary by driver. Roughly:

| Counter that moved                                   | Meaning | Bigger TX ring helps? |
|------------------------------------------------------|---------|-----------------------|
| `tx_restart_queue`, `tx_busy`, `tx_queue_N_restart`  | Ring filled, queue paused. Backpressure, **not loss**. | No, unless `tx_dropped` climbs with it. |
| `tx_fifo_errors`, driver's own `tx_dropped`          | Driver discarded packets it couldn't queue. | **Yes, this is the case.** |
| `tx_dma_failed`, `tx_timeout*`, `*_hang`, `*_err*`   | Hardware or driver fault. | No. Check `dmesg` (NETDEV WATCHDOG), driver and firmware versions (`ethtool -i`). |
| `carrier_changes` went up                            | Packets dropped while the link was down. | No. Fix the cable, switch port or autonegotiation. |

Also check byte queue limits: `cat /sys/class/net/$NIC/queues/tx-*/byte_queue_limits/{limit,inflight}`. If BQL caps in-flight bytes well below what the ring holds, a bigger ring changes nothing.

In practice, genuine ring-full TX drops are rare on modern drivers, because the driver pauses the queue before the ring overflows. When the test points at the driver, it's more often a fault (DMA, timeout, link) than a ring that's too small.

### How the script reports TX

In the NIC section (since boot):

| Situation                     | Result | What to do |
|-------------------------------|--------|------------|
| No TX drops                   | INFO   | Nothing. Longer queues only add latency. |
| TX drops since boot           | WARN   | Shows both counters. The live sample locates new drops. |

In the live sample (per NIC, over the sample window):

| Situation                                        | Result | NOTE added |
|--------------------------------------------------|--------|------------|
| No new drops                                     | OK     | Lists any driver TX counters that moved, for context. |
| Qdisc dropped grew                               | FAIL   | Qdisc remedies; don't raise the TX ring. |
| Interface grew, qdisc didn't, carrier changed    | FAIL   | Fix the link. |
| Interface grew, qdisc didn't, fault counters moved | FAIL | Driver/firmware fault; ring won't help. |
| Interface grew, qdisc didn't, TX ring below max  | FAIL   | Raise the TX ring. |
| Interface grew, qdisc didn't, TX ring at max     | FAIL   | Check the matching driver counter and BQL. |
| `tc` not installed                               | FAIL   | Install iproute2 to tell them apart. |

Qdisc remedies:

```bash
tc -s qdisc show dev eno1                       # per-qdisc "dropped" and backlog
ip link set dev eno1 txqueuelen 5000            # pfifo_fast only; not persistent

sysctl -w net.core.default_qdisc=fq_codel       # for new qdiscs
tc qdisc replace dev eno1 root mq               # rebuild children with the new default
# single-queue NIC: tc qdisc replace dev eno1 root fq_codel
```

**Why `fq_codel` suits voice:** it keeps a separate queue per flow and keeps queueing delay short. A bulk transfer on the same link can't fill a single shared FIFO and delay every RTP packet behind it. Most current distributions already default to `fq_codel`.

**Why not just make txqueuelen huge:** a longer FIFO turns drops into delay. For voice, a packet delayed by 100 ms behind a backup transfer is as useless as a dropped one, and it delays every packet behind it too (bufferbloat).

---

## 12. Drop counters and the live sample

Sections: **Drop counters since boot** and **Live Ns sample (is it happening right now?)**

These are the evidence sections. Settings tell you what *could* go wrong; counters tell you what *did*.

### UDP counters (`/proc/net/snmp`, `/proc/net/snmp6`)

| Counter          | Meaning                                                              |
|------------------|----------------------------------------------------------------------|
| `RcvbufErrors`   | Packet arrived, socket's receive buffer was full, packet dropped.   |
| `SndbufErrors`   | Send buffer full when the application tried to send.                |
| `InErrors`       | All inbound UDP errors, *including* RcvbufErrors and checksum errors.|
| `MemErrors`      | Global `udp_mem` limit hit.                                          |
| `NoPorts` (not shown) | Packet to a port nobody listens on. Not an error on this box.   |

Live view:

```bash
nstat -az | grep -E 'Udp(6)?(RcvbufErrors|SndbufErrors|InErrors|MemErrors)'
watch -d -n1 'nstat -az Udp*Errors'
```

### softnet_stat

`/proc/net/softnet_stat` has one row per CPU, in hex. Column 1 is packets processed, column 2 is backlog drops, column 3 is `time_squeeze`. The script sums them and, if any row dropped, lists which rows.

```bash
# decoded view, one line per CPU
awk '{printf "row %2d processed %d dropped %d squeezed %d\n", NR-1,
      strtonum("0x"$1), strtonum("0x"$2), strtonum("0x"$3)}' /proc/net/softnet_stat
```
(`strtonum` needs gawk.)

Drops concentrated on one or two rows suggest one CPU is overloaded: an IRQ landing on a busy core, poor RSS hashing (section 11), or RPS steering everything to one CPU.

### CPU steal (VMs only)

Steal is time your vCPU was ready to run but the hypervisor ran something else. For media it shows up as bursty jitter and late packets even when every buffer is big enough.

* The script shows steal since boot, and a live percentage during the sample.
* WARN at 2% or more during the sample.
* Steal can't be fixed from inside the guest: move the VM to a less loaded host, give it dedicated or pinned vCPUs, or run media on bare metal.

### The live sample

Counters since boot can be months old. The live sample (default 5 s, `SAMPLE=` to change) reads the counters twice and reports only what changed:

* `UdpRcvbufErrors` grew: **FAIL**, drops happening now.
* softnet drops grew: **FAIL**.
* `InErrors` grew: WARN.
* Steal percentage for the window.
* Per physical NIC: interface `tx_dropped` and root qdisc `dropped` over the window, plus the driver TX counters that moved, to say whether new TX loss is in the qdisc or the driver. The result and its NOTE are described in section 11 under "How the script reports TX".

TX drops are often intermittent, so a 5-second window can miss them. When chasing TX loss, use a longer window during peak: `SAMPLE=60 sudo bash freeswitch-tuning-audit.sh`.

Run the audit during your busiest hour for the live sample to mean something. A quiet 5 seconds at 3 a.m. proves little.

---

## 13. Kernel log patterns

Section header: **Kernel log**

The script reads `dmesg` (or `journalctl -k -b`) and counts these patterns, showing the most recent match:

| Pattern                                   | Level | Meaning / next step |
|-------------------------------------------|-------|---------------------|
| `nf_conntrack: table full`                | FAIL  | Packets silently dropped. Raise `nf_conntrack_max` or notrack RTP (section 7). |
| `Out of memory: Killed process`           | FAIL  | OOM killer ran. Check what was killed and why memory ran out. |
| `neighbour table overflow`                | WARN  | ARP/ND cache full. Raise `net.ipv4.neigh.default.gc_thresh1/2/3` (and ipv6) if many hosts share your L2 segment. |
| `clocksource ... unstable` / `Marking clocksource` | WARN | Kernel switched away from TSC. Check BIOS power settings, firmware, VM migrations (section 9). |
| `hrtimer: interrupt took`                 | WARN  | Timer interrupt ran long; usually a symptom of SMIs, firmware, or a stalled VM. |
| `NETDEV WATCHDOG` / `Link is Down`        | WARN  | TX hang or link flap. Check cables, switch port, driver/firmware versions. |

The log ring buffer only covers the current boot, and on busy systems only its most recent part. For older history use `journalctl -k --since "-7d"` if the journal is persistent.

---

## 14. Applying and persisting changes

### sysctl

1. Copy the suggested block from the report into `/etc/sysctl.d/90-freeswitch.conf`, keeping the comment lines so you remember which finding each line came from.
2. Remove anything you've decided not to change.
3. Apply and verify:
   ```bash
   sysctl --system
   sysctl net.core.rmem_max net.core.netdev_max_backlog vm.swappiness
   ```

**Ordering:** files in `/etc/sysctl.d/`, `/run/sysctl.d/` and `/usr/lib/sysctl.d/` are applied together in alphabetical order of file name, and the last value wins. A vendor file named `99-something.conf` will override your `90-freeswitch.conf`. Find conflicts with:

```bash
grep -rH 'rmem_max\|netdev_max_backlog' /etc/sysctl.d /run/sysctl.d /usr/lib/sysctl.d /etc/sysctl.conf
```

Some keys (the `nf_conntrack_*` ones) only exist after the module loads. If they're not applied at boot, add `nf_conntrack` to `/etc/modules-load.d/`.

### NIC settings (ethtool, txqueuelen)

`ethtool -G`, `ethtool -L`, `ethtool -N` and `ip link set ... txqueuelen` are lost on reboot or driver reload. Persist them with whatever manages your network.

The examples below persist a larger **RX** ring, once ring overflows (section 11) justify it. The lines marked *conditional* are only for the specific evidence described in section 11; don't add them by default:

* **TX ring:** only when TX loss is in the driver, not the qdisc.
* **txqueuelen:** only when there are TX drops on `pfifo_fast` and you can't switch to `fq_codel`.

**systemd-networkd / udev `.link` file** (works on most systemd systems):

```ini
# /etc/systemd/network/10-eno1.link
[Match]
MACAddress=aa:bb:cc:dd:ee:ff          # the NIC's permanent MAC (ip link show eno1)

[Link]
# A matching .link file replaces 99-default.link for this NIC,
# so keep the default naming policy or the NIC may lose its name:
NamePolicy=keep kernel database onboard slot path
AlternativeNamesPolicy=database onboard slot path
MACAddressPolicy=persistent
RxBufferSize=4096
# TxBufferSize=4096          # conditional
# TransmitQueueLength=5000   # conditional
```

Test with `udevadm test-builtin net_setup_link /sys/class/net/eno1` before rebooting.

**NetworkManager:**

```bash
nmcli connection modify eno1 ethtool.ring-rx 4096
# nmcli connection modify eno1 ethtool.ring-tx 4096   # conditional
nmcli connection up eno1      # reapplies the connection: brief interruption
```

**ifupdown (`/etc/network/interfaces`):**

```
iface eno1 inet static
    ...
    post-up /sbin/ethtool -G eno1 rx 4096
    # post-up /sbin/ethtool -G eno1 tx 4096                 # conditional
    # post-up /sbin/ip link set dev eno1 txqueuelen 5000    # conditional
```

**udev rule (txqueuelen only, conditional):**

```
# /etc/udev/rules.d/60-txqueuelen.rules
SUBSYSTEM=="net", ACTION=="add", KERNEL=="eno1", ATTR{tx_queue_len}="5000"
```

### Kernel command line (THP, C-states)

Edit `GRUB_CMDLINE_LINUX` in `/etc/default/grub`, then `update-grub` (Debian/Ubuntu) or `grub2-mkconfig -o /boot/grub2/grub.cfg` (RHEL family), and reboot.

### After any change

Re-run the audit, and re-run it during peak load a day later. The goal is zero growth in the live sample at peak, not all-green settings.

---

## 15. Triage: from symptom to check

```
                        Audio problem reported
                                 |
              +------------------+------------------+
              |                                     |
       One-way / no audio                  Choppy / robotic / gaps
              |                                     |
   +----------+----------+              Live sample: drops growing?
   |                     |                  |                 |
 SIP ALG loaded?   conntrack table        yes                 no
 (sec 7, FAIL)     full? (sec 7, 13)       |                  |
   |                     |           Which counter?      Steal high? (sec 12)
 remove it          raise max /            |              Swap in use? (sec 8)
                    notrack RTP     +------+-------+      Governor/C-states? (sec 10)
                                    |      |       |      Clocksource? (sec 9)
                         UdpRcvbuf  softnet  NIC rx_missed     |
                         Errors     dropped  / fifo        latency, not loss:
                            |         |         |          fix the stall source
                     rmem_default  backlog,  RX ring,
                     (sec 4);      RSS/RPS   queues,
                     then check    balance   IRQs
                     CPU / reader  (sec 5,   (sec 11)
                                    11, 12)
                                         
       Calls fail to set up under load
                    |
      +-------------+-------------+-----------------+
      |             |             |                 |
  conntrack     max_map_count  ephemeral/RTP    TCP/TLS phones
  full          / threads-max  overlap          can't reconnect
  (sec 7)       (sec 8)        (sec 6)          somaxconn,
                                                syn_backlog (sec 5)
```

If the audit is clean and the live sample shows no drops at peak, the problem is very likely outside this box: the network path, the carrier, the far-end NAT/firewall (check for a SIP ALG there), or the FreeSWITCH configuration itself.

---

## 16. Quick reference

### sysctl targets used by the audit

| Key | Target | Level | Section |
|-----|--------|-------|---------|
| `net.core.rmem_max` | >= 16777216 | WARN | 4 |
| `net.core.wmem_max` | >= 16777216 | WARN | 4 |
| `net.core.rmem_default` | >= 1048576 | WARN | 4 |
| `net.core.wmem_default` | >= 524288 | INFO | 4 |
| `net.ipv4.udp_rmem_min` | >= 16384 | INFO | 4 |
| `net.ipv4.udp_wmem_min` | >= 16384 | INFO | 4 |
| `net.core.netdev_max_backlog` | >= 16384 | WARN | 5 |
| `net.core.netdev_budget` | >= 600 | INFO | 5 |
| `net.core.somaxconn` | >= 4096 | INFO | 5 |
| `net.ipv4.tcp_max_syn_backlog` | >= 4096 | INFO | 5 |
| `net.ipv4.tcp_keepalive_time` | <= 600 | INFO | 5 |
| `net.netfilter.nf_conntrack_max` | >= 262144 | WARN | 7 |
| `net.netfilter.nf_conntrack_udp_timeout_stream` | >= 120 | INFO | 7 |
| `vm.swappiness` | <= 10 | WARN | 8 |
| `vm.max_map_count` | >= 262144 | WARN | 8 |
| `kernel.threads-max` | >= 32768 | WARN | 8 |
| `kernel.pid_max` | >= 131072 | INFO | 8 |
| `fs.file-max` | >= 2097152 | INFO | 8 |
| `fs.nr_open` | >= 1048576 | INFO | 8 |

### Commands worth knowing

```bash
# UDP and softnet drops
nstat -az | grep -i udp
cat /proc/net/softnet_stat

# NIC
ethtool -g  <nic>          # rings
ethtool -l  <nic>          # queues
ethtool -S  <nic>          # driver counters
ethtool -n  <nic> rx-flow-hash udp4
tc -s qdisc show dev <nic>
ip -s link show <nic>

# conntrack
conntrack -C               # entry count
conntrack -S               # per-CPU stats incl. drops, insert_failed
lsmod | grep -E 'nf_(conntrack|nat)_sip'

# timing / CPU
cat /sys/devices/system/clocksource/clocksource0/current_clocksource
cpupower frequency-info
mpstat -P ALL 1            # per-CPU load incl. %steal, %soft
```