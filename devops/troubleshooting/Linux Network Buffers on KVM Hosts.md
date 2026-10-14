# Linux Network Buffers on KVM Hosts: Rings, txqueuelen and rmem/wmem

Oct 14, 2026

## Overview: where packets wait on a KVM host

Every packet on a hypervisor passes through a chain of fixed-size buffers, and a packet is lost wherever one of them is full when it arrives. Receive and transmit fail differently: on receive nothing can tell the sender to slow down, so a full buffer drops; on transmit the kernel can usually pause the sender, so a full buffer queues.

This guide covers four groups of settings that are often confused because their names sound alike:

| Setting | Lives in | Applies to | Full means |
| --- | --- | --- | --- |
| RX ring (`ethtool -G rx`) | NIC hardware/driver | All received traffic, host and VMs | Packet dropped by the NIC |
| TX ring (`ethtool -G tx`) | NIC hardware/driver | All transmitted traffic | Packets wait in the qdisc |
| `netdev_max_backlog`, `netdev_budget` | Kernel, per CPU | Received packets awaiting processing | Packet dropped (softnet `dropped`) |
| `txqueuelen` + qdisc | Kernel, per interface | Packets waiting to leave an interface | Packet dropped (`tx_dropped`) |
| `rmem` / `wmem`, `tcp_*mem`, `udp_mem` | Kernel, per socket | Only connections that end on the host itself | Sender throttled (TCP) or datagram dropped (UDP) |

The last row is the one most often misapplied: guest TCP sessions end inside the guest kernel, so the host's socket buffer settings never touch VM traffic. The diagram below shows the path and where each buffer sits.

```text
  INTO A VM (wire -> guest)             OUT OF A VM (guest -> wire)

            from wire                             guest app
  +-----------v-----------+             +-----------v-----------+
  | NIC RX ring    [DROP] |             | Guest virtio TX ring  |
  | ethtool -G rx         |             | (inside the guest)    |
  +-----------+-----------+             +-----------+-----------+
              |                                     |   via tap
  +-----------v-----------+             +-----------v-----------+
  | Softirq (NAPI)        |----+        | CPU backlog    [DROP] |
  | netdev_budget         |    |        | netdev_max_backlog    |
  +-----------+-----------+    |        +-----------+-----------+
              |                |                    |
  +-----------v-----------+    |        +-----------v-----------+
  | Bridge / OVS          |    |        | Bridge / OVS          |
  | noqueue, no buffer    |    |        | noqueue, no buffer    |
  +-----------+-----------+    |        +-----------+-----------+
              |                |                    |
  +-----------v-----------+    |        +-----------v-----------+
  | Tap ring       [DROP] |    |        | NIC qdisc      [DROP] |
  | txqueuelen            |    |        | txqueuelen or limit   |
  +-----------+-----------+    |        +-----------+-----------+
              |                |                    |
  +-----------v-----------+    |        +-----------v-----------+
  | Guest virtio RX ring  |    |        | NIC TX ring    [WAIT] |
  | (inside the guest)    |    |        | ethtool -G tx         |
  +-----------+-----------+    |        +-----------+-----------+
              |                |                    |
          guest app            |                 to wire
                               |
                               v
                    +-----------------------+
                    | Host sockets          |
                    | rmem/wmem, tcp_mem    |
                    | host traffic only,    |
                    | never VM traffic      |
                    +-----------------------+

[DROP] full = packets lost   [WAIT] full = packets queue in the qdisc
Unmarked stages pass packets through without a buffer of their own.
```

On the way in, the NIC RX ring and the VM's tap ring are where packets are lost; on the way out, the per-CPU backlog and the NIC's qdisc are, while a full NIC TX ring only makes packets wait.

## NIC RX ring buffer

The RX ring is a circular list of empty buffers the driver gives the NIC in advance; when a packet arrives, the NIC copies it into the next free slot by DMA. If every slot is full because the CPU hasn't processed earlier packets yet, the NIC has nowhere to put the new one and discards it. The sender is never told.

**Why it overflows:** bursts. A 10 Gb/s link can deliver about 820,000 full-size (1500-byte) packets a second, and up to 14.9 million minimum-size ones. A 512-slot ring absorbs well under a millisecond of full-size traffic if the CPU is briefly busy with something else.

**Check the size:**

```bash
ethtool -g eno1
```

ethtool prints the hardware maximums first and the current settings second. Some newer versions omit the section headers, so read by position: the first `RX:` value is the maximum, the second is current.

**Check for overflow** (counter names vary by driver):

```bash
ethtool -S eno1 | grep -Ei 'miss|no_buf|fifo|discard|rxbds_empty'
cat /sys/class/net/eno1/statistics/rx_missed_errors
```

A non-zero counter that rises during traffic peaks means the ring is too small or the CPU handling that queue is too busy.

**Resize:**

```bash
ethtool -G eno1 rx 4096
```

- Most server drivers (ixgbe, i40e, ice, bnxt, tg3, mlx5) reset the link when the ring changes, which drops every VM on the host for a second or two. Do it in a maintenance window, from a console if it's your management link.
- 4096 is a common target even when the maximum is 8192: a very large ring holds more stale data in memory and cache for little extra protection.
- The setting is lost on reboot. Persist it with `nmcli connection modify <conn> ethtool.ring-rx 4096` (NetworkManager, EL8/EL9) or a `post-up /usr/sbin/ethtool -G eno1 rx 4096` line in `/etc/network/interfaces` (Debian/Proxmox).

**When not to bother:** if the overflow counters are zero, a small ring isn't hurting you. Raising it is preventive, not a fix.

## NIC TX ring buffer

The TX ring is the same structure in the other direction: the driver fills slots with outgoing packets and the NIC sends them. Unlike receive, a full TX ring rarely loses packets, because the kernel knows the ring is full and pauses that queue. Outgoing packets then wait in the interface's qdisc until the NIC frees slots.

**Byte Queue Limits (BQL)** make a bigger TX ring even less useful. BQL caps how many bytes the kernel puts into the TX ring at once, sized to what the link can send in a few milliseconds. The rest is deliberately held back in the qdisc, where `fq_codel` can keep latency low. A larger ring just gives BQL more room it won't use.

**Where TX pressure shows up:**

```bash
tc -s qdisc show dev eno1
```

Look at `requeues`, the number of times a packet was handed to the driver, bounced because the ring was full, and put back. Judge it as a share of packets sent, not as a raw number: a few hundred thousand requeues on hundreds of billions of packets is noise.

**When a bigger TX ring helps:**

- Requeues are a meaningful share of packets sent (0.1% or more is worth a look).
- The kernel log shows `NETDEV WATCHDOG: eno1 ... transmit queue N timed out`. That means the NIC stopped draining its ring entirely, which usually points at a driver or firmware fault rather than size, but it's the TX side failing either way.

```bash
ethtool -G eno1 tx 4096
```

The same link-reset caution as RX applies. If the TX ring is already at its maximum and requeues stay high, the link itself is saturated: check throughput with `sar -n DEV 1`.

## Receive-side kernel queues: netdev_max_backlog and netdev_budget

There is no `rxqueuelen`. Linux keeps no per-interface software queue for received packets; once the NIC hands them over, the kernel processes them as fast as the CPU allows. The closest equivalent is the per-CPU backlog queue, sized by `net.core.netdev_max_backlog`.

**What uses the backlog:** packets that arrive through software rather than straight from a NIC queue. On a KVM host that includes packets coming out of tap devices (VM transmit), packets steered to another CPU by RPS, and packets from some tunnel and virtual devices. When a CPU's backlog is full, new packets for that CPU are dropped.

**What drains it:** softirq processing, limited per run by `net.core.netdev_budget` (packets, default 300) and `net.core.netdev_budget_usecs` (time, default 2000 µs on recent kernels). When a run hits either limit with work still waiting, the kernel stops and counts a `time_squeeze`.

**Check per CPU:**

```bash
awk '{printf "CPU%-3d dropped=%d squeeze=%d\n", NR-1, strtonum("0x"$2), strtonum("0x"$3)}' /proc/net/softnet_stat
```

- `dropped` above zero = the backlog overflowed on that CPU. These counters are cumulative since boot, so sample twice and compare.
- High `time_squeeze` = that CPU keeps running out of budget before its queue is empty. A few CPUs with far higher numbers than the rest means traffic is concentrated, usually a few heavy flows or interrupts pinned to few CPUs.
- Drops all on one CPU point to one source: a single heavy flow (a flood to or from one VM) or one VM's vhost thread pushing a burst. Raising the backlog adds headroom; it doesn't fix the flood.

**History** is in sysstat if collection is enabled: `sar -n SOFT -P ALL -f /var/log/sa/saDD` shows `dropd/s` and `squeezd/s` per CPU for each 10-minute interval.

**Tune:**

```ini
net.core.netdev_max_backlog = 16384
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 4000
```

These are safe on hosts with spare CPU. A larger budget lets one softirq run longer before yielding, which costs a little latency for other work on that CPU.

## txqueuelen and qdiscs

`txqueuelen` is the length, in packets, of an interface's outbound software queue. Whether it matters depends on which queueing discipline (qdisc) the interface uses, because some qdiscs use it as their limit and some ignore it.

| qdisc | Typical on | Uses txqueuelen? | Notes |
| --- | --- | --- | --- |
| `pfifo_fast` | Older kernels and distros | Yes, as the queue limit | Simple FIFO; a short queue drops bursts |
| `fq_codel` | Default on EL8+, Debian/Proxmox | No, has its own limit (10240 packets) | Keeps latency low by dropping from the fattest flow |
| `mq` | Multi-queue physical NICs | Not directly | A parent with one child qdisc (usually `fq_codel`) per hardware queue |
| `noqueue` | Bridges, OVS ports, VXLAN, loopback | No queue at all | Packets pass straight through; txqueuelen is irrelevant |

**Check an interface:**

```bash
ip -s link show eno1            # qlen and TX dropped
tc -s qdisc show dev eno1       # qdisc, drops, requeues, backlog
```

**Judge drops as a percentage:** `tx_dropped / (tx_packets + tx_dropped)`. On a physical NIC with `mq` + `fq_codel`, zero or near-zero is normal. As a rough scale: under 0.01% is noise, 0.01–1% is real intermittent loss, and 1% or more means that interface is regularly losing traffic.

**Change it:**

```bash
ip link set dev eno1 txqueuelen 10000
```

This takes effect immediately with no link reset, but it only matters on a `pfifo_fast`-style qdisc. On `fq_codel`, change the qdisc's own `limit` instead, or leave it alone.

**The tradeoff is latency.** A longer queue drops less during a burst but holds more packets when it's full. Every packet in the queue waits behind the ones ahead of it, so a long, full queue adds delay to every flow through that interface (bufferbloat). Raise it only where you've measured drops. Tap devices are the exception to the qdisc rules above, covered next.

## Tap and vnet devices: the direction flips

On a VM's tap device, the host's TX is the guest's RX. A tap is a pipe between the host kernel and the VM's virtual NIC, and its counters are always from the host's point of view:

| Host counter on the tap | Traffic direction | Buffer involved |
| --- | --- | --- |
| TX (`tx_packets`, `tx_dropped`) | Into the VM | The tap's internal ring, then the guest's virtio RX ring |
| RX (`rx_packets`, `rx_dropped`) | Out of the VM | The guest's virtio TX ring, then the host backlog queue |

**What `tx_dropped` on a tap means:** the host had packets for the VM, but vhost-net couldn't hand them over because the guest's virtio RX ring was full. The tap's own ring, sized by its `txqueuelen` (default 1000 on current kernels, 500 on some older setups), filled up and the overflow was dropped. These are packets that never reached the guest.

**Common causes, in order of likelihood:**

1. The guest was busy or starved of CPU and didn't empty its receive ring in time. Check inside the guest: `top` or `vmstat 1` for high CPU and `st` (steal), and its own `ip -s link` RX drops.
2. One virtio queue is doing all the work for a busy VM. Enabling virtio-net multiqueue for that VM spreads receive across its vCPUs.
3. Nothing was reading the tap: the VM was booting, shutting down or migrating, or its NIC was down inside the guest. Broadcast and multicast traffic still arrives in those windows and is dropped. This produces drops without any real problem.

**Judge by percentage, and check whether it's still climbing:**

```bash
ip -s link show sol-104
sleep 60; ip -s link show sol-104
```

The counters reset when the VM starts, so a tap's totals cover its uptime. A handful of drops against hundreds of millions of packets that aren't increasing is cause 3. Drops that climb while the VM is running are cause 1 or 2.

**Raise the queue (only for taps with real drops):**

```bash
ip link set dev sol-104 txqueuelen 5000
```

Taps are recreated every time a VM starts, so persist it with a udev rule. Match the name prefix your platform uses (`vnet` for libvirt, `tap` for Proxmox, `sol-` for SolusVM 2):

```
# /etc/udev/rules.d/60-txqueuelen.rules
SUBSYSTEM=="net", ACTION=="add", KERNEL=="vnet*|tap*", ATTR{tx_queue_len}="5000"
```

A longer queue gives a briefly busy guest more slack. If one guest drops constantly, it's undersized or overloaded, and the fix is inside that VM: more vCPUs, less load, or multiqueue.

## rmem, wmem and TCP/UDP socket buffers

Socket buffer settings only apply to sockets that a process on the host opens. A guest's TCP connection ends inside the guest's kernel, so the host has no socket for it; VM traffic passes through the host as raw frames and never meets these limits. Tune them inside each guest for the guest's own traffic.

**What they do cover on a hypervisor:** SSH and the management agent, VNC/console sessions, live migrations, backups, and above all remote storage. If VM disks sit on NFS or iSCSI, a stall on the host's storage connection freezes the VM, which looks exactly like a network drop from outside.

| Setting | Controls | Default (typical) |
| --- | --- | --- |
| `net.core.rmem_default` / `wmem_default` | Starting buffer size for non-TCP sockets | 212992 bytes |
| `net.core.rmem_max` / `wmem_max` | Ceiling an application can request with `setsockopt` | 212992 bytes |
| `net.ipv4.tcp_rmem` / `tcp_wmem` | TCP's min, default and max per socket; autotuning grows buffers up to the max | max about 6 MB receive, 4 MB send |
| `net.ipv4.tcp_mem` | Total memory for all TCP sockets, in pages: below pressure, pressure starts, hard limit | Sized from RAM at boot |
| `net.ipv4.udp_mem` | The same three thresholds for UDP | Sized from RAM at boot |

**How each fails:**

- **TCP:** a small buffer limits throughput, not reliability. TCP's window shrinks to fit, so a long-distance transfer runs slower but doesn't drop. Only when total TCP memory passes `tcp_mem` pressure does the kernel start pruning queues.
- **UDP:** a full receive buffer drops datagrams silently. UDP has no flow control, so this is real loss.

**Check whether host sockets are struggling:**

```bash
nstat -az | grep -Ei 'RcvbufErrors|SndbufErrors|MemoryPressures|PruneCalled|RcvPruned|RcvQDrop'
cat /proc/net/sockstat
```

Non-zero `UdpRcvbufErrors` means host UDP sockets are overflowing. Rising `TCPMemoryPressures` or a `TCP: out of memory -- consider tuning tcp_mem` line in `dmesg` means TCP is hitting its global limit. All zeros means socket buffers aren't your problem.

**Prove VM traffic bypasses them:** run a large transfer inside one VM and watch the host. The tap's byte counters climb fast while the host's TCP segment counters barely move.

```bash
watch -n1 'nstat -az TcpInSegs TcpOutSegs; ip -s link show vnetX'
```

**Reasonable host values** for fast storage and migration traffic:

```ini
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
```

The exception is QEMU user-mode (SLIRP) networking, where QEMU opens real host sockets on the guest's behalf. Production KVM platforms don't use it.

## Diagnosis cheat sheet

Start from the counter that's moving, not from the setting you suspect. Each row below is one place a packet can be lost or delayed, with the command that shows it and the fix that addresses it.

| Counter rising | Command | Where the loss is | Fix |
| --- | --- | --- | --- |
| `rx_missed_errors`, `rx_no_buffer`, `rx_fifo_errors`, `rxbds_empty` | `ethtool -S eno1` | NIC RX ring full | `ethtool -G eno1 rx 4096`; more RX queues; spread IRQs |
| softnet `dropped` | `/proc/net/softnet_stat`, `sar -n SOFT -P ALL` | Per-CPU backlog full | Raise `netdev_max_backlog`; find the heavy flow if one CPU |
| softnet `time_squeeze` (high on few CPUs) | same | Softirq budget exhausted | Raise `netdev_budget`; spread load across CPUs |
| `tx_dropped` on a VM tap | `ip -s link show <tap>` | Packets into the VM, guest not draining | Check guest CPU/steal; virtio multiqueue; raise tap `txqueuelen` |
| `tx_dropped` on a physical NIC | `ip -s link`, `tc -s qdisc` | Outbound qdisc full | Raise `txqueuelen` (pfifo_fast) or qdisc `limit` |
| qdisc `requeues` (0.1%+ of packets) | `tc -s qdisc show dev eno1` | NIC TX ring full | `ethtool -G eno1 tx 4096`, or link saturated |
| `NETDEV WATCHDOG ... timed out` | `dmesg`, `journalctl -k` | NIC stopped transmitting | Driver/firmware update; check hardware |
| `UdpRcvbufErrors` | `nstat -az` | Host UDP socket buffer full | Raise `rmem_max`/app buffer (host traffic only) |
| `TCPMemoryPressures`, `TCP: out of memory` | `nstat -az`, `dmesg` | Host TCP memory limit | Raise `tcp_mem` (host traffic only) |
| `IPReversePathFilter` | `nstat -az TcpExtIPReversePathFilter` | Strict rp_filter rejecting asymmetric routes | `net.ipv4.conf.all.rp_filter = 2` |

All of these are cumulative counters. Sample twice, a minute apart, during or right after a reported incident: a counter that isn't moving describes the past, not the problem in front of you.

## Recommended baseline and safe change procedure

For a baremetal KVM host running 10–20+ VMs, these values give headroom without meaningful cost. Treat them as a starting point, then adjust where counters show pressure.

| Setting | Baseline | Applied with | Disruptive? |
| --- | --- | --- | --- |
| `net.core.netdev_max_backlog` | 16384 | sysctl | No |
| `net.core.netdev_budget` | 600 | sysctl | No |
| `net.core.netdev_budget_usecs` | 4000 | sysctl | No |
| `net.core.rmem_max` / `wmem_max` | 16777216 | sysctl | No |
| `net.ipv4.tcp_rmem` / `tcp_wmem` max | 16777216 | sysctl | No (new connections only) |
| NIC RX ring | 4096, or max if lower | ethtool | Yes, link resets on most drivers |
| NIC TX ring | Driver default unless requeues are high | ethtool | Yes, link resets on most drivers |
| Physical NIC `txqueuelen` | 1000 default (matters only on pfifo_fast) | ip link | No |
| VM tap `txqueuelen` | 1000 default; 5000 for taps with real drops | ip link + udev | No |

**Changing sysctls:**

1. Check whether the platform ships its own sysctl files first: `ls /etc/sysctl.d/ /usr/lib/sysctl.d/` and grep for the keys. Files apply in alphabetical order and the last one wins, so a vendor `99-` file overrides yours.
2. Put your values in one file, e.g. `/etc/sysctl.d/90-hypervisor.conf`, named to sort after anything it should override.
3. Apply with `sysctl --system`, then read the values back with `sysctl <key>` to confirm they took.

**Changing NIC rings or queues:**

1. Schedule a maintenance window: on a hypervisor, a link reset is an outage for every VM.
2. Work from the out-of-band console if the NIC carries your management traffic.
3. Apply with `ethtool -G` / `ethtool -L`, confirm with `ethtool -g` / `-l`, then persist (NetworkManager `ethtool.ring-rx` / `ethtool.ring-tx`, or an ifupdown `post-up` line).

**After any change:** keep sysstat collecting (`systemctl enable --now sysstat`), and compare `sar -n SOFT` and `sar -n DEV` before and after. A change that made a counter stop rising worked; one that only moved drops somewhere else didn't.