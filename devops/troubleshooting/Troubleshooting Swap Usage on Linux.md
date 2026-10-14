#### Troubleshooting Swap Usage on Linux

A practical guide for working out why a Linux host is using swap, whether it matters, and what to do about it. Covers general bare-metal servers first, then the extra checks for KVM/QEMU hypervisors.

#### Contents

1. [Read `free` correctly](#1-read-free-correctly)
2. [Is the swap actually hurting?](#2-is-the-swap-actually-hurting)
3. [Where is the memory going?](#3-where-is-the-memory-going)
4. [Who owns the swap?](#4-who-owns-the-swap)
5. [Settings and layout](#5-settings-and-layout)
6. [Limits and history](#6-limits-and-history)
7. [Common patterns](#7-common-patterns)
8. [KVM / QEMU hypervisors](#8-kvm--qemu-hypervisors)
9. [Fixes](#9-fixes)
10. [What swappiness really does](#10-what-swappiness-really-does)
11. [Quick collection script](#11-quick-collection-script)

---

#### 1. Read `free` correctly

```
free -h
```

| Column | Meaning |
|---|---|
| `used` | Memory held by processes and the kernel, excluding cache |
| `free` | Completely unused memory. Being near zero is normal |
| `buff/cache` | Page cache and buffers. Mostly reclaimable |
| `available` | Estimate of what could be handed to applications without swapping |

Key points:

- Low `free` is not a problem. Linux uses spare RAM for cache on purpose.
- `available` is the number that matters, but it is an estimate. It counts cache as reclaimable, and it does not tell you whether the host is overcommitted.
- **Large `buff/cache` alongside full swap** is the pattern worth investigating: the kernel chose to swap process memory while holding droppable cache.

---

#### 2. Is the swap actually hurting?

Full swap does not mean ongoing pressure. Pages swapped out during a past event stay in swap until something touches them.

```
vmstat 1 10
cat /proc/pressure/memory        # kernel 4.20+ (or backported)
sar -B 1 5; sar -W 1 5           # needs sysstat
```

What to look at:

| Signal | Healthy | Problem |
|---|---|---|
| `vmstat` `so` (swap out) | 0 | Sustained non-zero: active memory pressure |
| `vmstat` `si` (swap in) | 0 or a trickle | Sustained high: processes waiting on swapped pages |
| PSI `some avg10` | Near 0 | Above a few percent: tasks stalling on memory |
| PSI `full avg10` | 0 | Anything above 0: everything stalled at times |
| `sar -B` `pgscand/s` | 0 | Non-zero: direct reclaim, processes stalled to free memory |
| `sar -B` `majflt/s` | Low | High: pages being read back from disk |

Interpretation:

- **`si` and `so` near zero**: swap is parked. Cosmetic, apart from the lack of cushion if swap is nearly full.
- **`si` trickle, `so` zero**: old swapped pages are occasionally touched. Minor latency cost.
- **Both sustained**: thrashing. Fix it now.

> A swap device that is close to 100% full is a risk in its own right, even when parked. There is no room left to absorb a spike, so the next step is the OOM killer.

---

#### 3. Where is the memory going?

```
cat /proc/meminfo
```

| Field | What it means | If it is large |
|---|---|---|
| `AnonPages` | Process heap and stack memory | Look at processes (section 4) |
| `Cached`, `Active(file)`, `Inactive(file)` | Page cache | Find what is doing the file I/O |
| `Shmem` | tmpfs and shared memory | Counts as cache but can only be reclaimed by swapping. Check `df -h -t tmpfs` and `ipcs -m` |
| `SUnreclaim` | Kernel slab that cannot be freed | Run `slabtop -o \| head -20` and look for a leak |
| `SReclaimable` | Reclaimable slab (dentries, inodes) | Usually harmless |
| `HugePages_Total` | Reserved hugepages | Unusable by anything else, even when empty |
| `Mlocked`, `Unevictable` | Memory that cannot be swapped | Pushes pressure onto everything else |
| `Committed_AS` vs `CommitLimit` | Memory promised vs what exists | Shows how overcommitted the box is |
| `AnonHugePages` | Transparent hugepages in use | Informational |

Tips:

- A large **`Inactive(file)`** with a tiny `Active(file)` and little `Mapped` means data was read or written once and never touched again. Typical of backups, large copies, and log processing.
- If the fields do not add up to `MemTotal`, the gap is usually kernel or driver memory. ZFS ARC is the classic example (`arc_summary`).

To see which files are in the page cache:

```
# util-linux 2.30+
find /path/to/suspect/dir -xdev -type f -size +1G 2>/dev/null | xargs fincore 2>/dev/null | sort -k1 -h | tail -20
```

---

#### 4. Who owns the swap?

```
# Swap per process, largest last (KB, PID, name)
for f in /proc/[0-9]*/status; do
  awk '/^Name/{n=$2} /^Pid/{p=$2} /^VmSwap/{if($2>0) print $2, p, n}' $f
done 2>/dev/null | sort -n | tail -20

# Largest resident processes
ps -eo pid,user,rss,vsz,comm --sort=-rss | head -20

# Nicer, if installed
smem -rs swap | head -20
```

Reading the result:

- **One big owner**: a leak or an oversized application (JVM heap, database buffer pool).
- **Many processes with a slice each**: host-wide pressure pushed out whatever was idle.
- **Per-process totals add up to more than the swap in use**: swapped pages are shared between processes (forked workers, or KSM on a hypervisor).

---

#### 5. Settings and layout

```
sysctl vm.swappiness vm.min_free_kbytes vm.zone_reclaim_mode vm.overcommit_memory
swapon --show
numastat -m
cat /sys/kernel/mm/transparent_hugepage/enabled
uname -r
```

| Check | Why |
|---|---|
| `vm.swappiness` | Bias between swapping and dropping cache (section 10) |
| `vm.zone_reclaim_mode` | Non-zero makes a NUMA node reclaim or swap locally instead of using another node. Usually should be 0 |
| `numastat -m` | One node full and the other empty means NUMA imbalance or pinning. See "Understanding NUMA" below |
| `swapon --show` | Device type, size, priority. Shows zram if present |
| `uname -r` | Older kernels (3.10, 4.18 era) balance reclaim more crudely and swap more readily with cache present |

#### Understanding NUMA

Most people never need to think about NUMA, because laptops, desktops, and small single-socket servers do not have it. It matters on larger servers, and it can make a host swap even when `free` shows plenty of memory.

**What NUMA is**

NUMA stands for Non-Uniform Memory Access. On a server with two (or more) CPU sockets, each CPU has its own bank of RAM physically wired to it. Linux treats each CPU and its RAM as a **node**:

```
   Node 0                      Node 1
+-----------+              +-----------+
|  CPU 0    |<-- link ---->|  CPU 1    |
|  128 GB   |              |  128 GB   |
+-----------+              +-----------+
```

- A CPU reading its own node's RAM ("local") is fast.
- Reading the other node's RAM ("remote") has to cross the link between sockets, so it is slower, often around 1.5 to 2 times the latency.
- To keep things fast, the kernel prefers to give a process memory from the node whose CPU it is running on.

Some single-socket servers, notably AMD EPYC with certain BIOS settings, also split themselves into several nodes.

**Does my server have it?**

```
lscpu | grep -i numa
numactl --hardware        # needs the numactl package
```

If it reports `NUMA node(s): 1`, the rest of this section does not apply to you. With two or more nodes, `numactl --hardware` lists each node's size and free memory, plus a distance table: `10` means local, and larger numbers (`20`, `21`, `32`) mean remote and slower.

**Why it matters for swap**

`free -h` adds all nodes together. The kernel, though, makes many memory decisions per node. So this can happen:

| | Node 0 | Node 1 | `free -h` shows |
|---|---|---|---|
| Total | 128 GB | 128 GB | 256 GB |
| Free | 0.5 GB | 60 GB | 60.5 GB |

The host looks fine overall, but node 0 is full. If processes on node 0 are not allowed to (or the kernel chooses not to) take memory from node 1, the kernel reclaims on node 0 instead: it drops node 0's cache and then swaps node 0's processes. You see swap activity on a host that seems to have 60 GB free.

The usual causes:

- **`vm.zone_reclaim_mode` is not 0.** This setting tells the kernel to free memory on the local node before using another node. It was turned on automatically by some older kernels on machines with large node distances. On most workloads it should be 0 (use the other node instead).
- **Processes or VMs are pinned to one node.** Tools such as `numactl --membind`, cpusets, container CPU/memory pinning, or libvirt's `<numatune mode='strict'>` force memory to come from a specific node. If too much is pinned to one node, that node runs out while the other sits idle.
- **Uneven placement.** Large processes or VMs that happened to start on the same node fill it up first.

**How to check for an imbalance**

```
numastat -m                       # per-node memory breakdown, in MB
numastat                          # per-node allocation counters
sysctl vm.zone_reclaim_mode
```

In `numastat -m`, compare `MemFree`, `FilePages`, and `AnonPages` across the node columns:

- **Similar on every node**: NUMA is not your problem. Move on.
- **One node with almost no `MemFree` while another has plenty**: an imbalance. Check `zone_reclaim_mode` and pinning.

In the plain `numastat` counters:

| Counter | Meaning |
|---|---|
| `numa_hit` | Memory was allocated on the node the process wanted |
| `numa_miss` | The preferred node was full, so memory came from another node |
| `numa_foreign` | Memory meant for this node was allocated somewhere else |
| `local_node` / `other_node` | Allocations made from the local node vs a remote node |

A growing `numa_miss` means the kernel is spilling over to other nodes rather than swapping. That is slower, but much better than swapping. If one node is full and `numa_miss` stays at zero, something is preventing the spill-over.

To see where a specific process's memory sits:

```
numastat -p <pid>                 # or a name pattern, e.g. numastat -p qemu
```

**On a KVM host**

Check whether any VMs are pinned to a node, and how strictly:

```
for v in $(virsh list --name); do echo "$v: $(virsh numatune $v 2>/dev/null | tr -s ' \n' ' ')"; done
```

| `numatune` mode | Behaviour |
|---|---|
| `strict` | The VM may only use memory from the listed nodes. If they fill, the host swaps or OOM-kills, even with other nodes free |
| `preferred` | Use the listed node first, then spill over |
| `interleave` | Spread memory evenly across the listed nodes |
| `restrictive` | Like `strict`, but enforced through cgroups (newer libvirt) |

No `numatune` output, or no nodeset, means the VM is not pinned and the kernel places its memory freely.

---

#### 6. Limits and history

```
systemd-cgtop -m
dmesg -T | grep -iE "oom|out of memory"
sar -r; sar -S
crontab -l; ls /etc/cron.d /etc/cron.daily; systemctl list-timers
```

- **cgroup limits**: a service or container with a memory limit swaps its own pages even when the host has plenty free. This looks baffling from `free` alone.
- **`sar` history**: shows when swap grew. Match the time against cron jobs, backups, or traffic peaks.
- **OOM messages**: confirm whether the box has already run out at some point.

#### The drop-caches test

If page cache is large and you want to know what fills it:

```
sync; echo 1 > /proc/sys/vm/drop_caches
```

This discards clean page cache only. It does not touch swap and is safe, though disk reads will be slower until the cache warms up again. Then watch `free -h` over the next day. A jump of tens of GB at a specific time points to a scheduled job.

---

#### 7. Common patterns

| Pattern | Likely cause |
|---|---|
| High `AnonPages`, one big process | Leak or oversized app |
| Big cache plus swap, `so` at zero | Old burst (backup, large copy), now parked |
| Big `Inactive(file)`, grows on a schedule | Backup or batch job reading through the page cache |
| High `Shmem` | tmpfs files or shared memory segments |
| High `SUnreclaim` | Kernel slab leak or a filesystem cache |
| Plenty free on the host, one service swapping | cgroup memory limit |
| One NUMA node empty, the other fine | NUMA imbalance or `zone_reclaim_mode` |
| Swap spread evenly across all processes or VMs | Host-wide pressure events or overcommit |

---

#### 8. KVM / QEMU hypervisors

Guest RAM is anonymous memory inside each QEMU process, so the host kernel can swap it like any other process memory. Four extra things to check.

#### 8.1 Disk cache mode

```
for v in $(virsh list --name); do
  echo "$v: $(virsh dumpxml $v | grep -o "cache='[^']*'" | sort -u | tr '\n' ' ')"
done
```

| Mode | Effect |
|---|---|
| `none` | O_DIRECT. Guest I/O bypasses the host page cache. Preferred |
| `writeback`, `writethrough` | Guest I/O goes through the host page cache, so data is cached twice and the host cache balloons |
| No attribute | Hypervisor default, often `writeback` |

If the modes are not `none`, switch them (pair with `io=native` for file-backed images). The change takes effect on a full stop and start of the VM, not a reboot from inside the guest.

If they are already `none` and the host still has a large page cache, something else on the host is generating it: backups, snapshots, image conversions, or migrations.

#### 8.2 Swap per VM

```
for p in $(pgrep -f qemu); do
  printf "%s %s\n" "$(awk '/VmSwap/{print $2}' /proc/$p/status)" \
    "$(tr '\0' ' ' < /proc/$p/cmdline | grep -o 'guest=[^, ]*')"
done | sort -n
```

- One outlier: a single oversized or misbehaving guest.
- Even spread: host-wide pressure or overcommit.

#### 8.3 KSM

```
cat /sys/kernel/mm/ksm/run /sys/kernel/mm/ksm/pages_shared /sys/kernel/mm/ksm/pages_sharing
systemctl is-active ksm ksmtuned
```

- `pages_shared` x 4 KB = physical RAM holding merged pages.
- `pages_sharing` x 4 KB = memory saved by merging.
- `run`: 0 = scanner paused (existing merges stay), 1 = scanning, 2 = unmerge everything.

Things to know:

- KSM savings are not guaranteed. They shrink when guests reboot or change workload.
- `ksmtuned` counts buffers and cache as free memory. A large host page cache keeps it above its threshold (20% of RAM by default), so it leaves scanning off.
- Merged pages can come back from swap as separate copies, so a swap drain may need more RAM than the swap-used figure.

#### 8.4 Overcommit

```
# Total RAM allocated to running guests, in KiB
for v in $(virsh list --name); do virsh dominfo $v | awk '/Max memory/{print $3}'; done | paste -sd+ | bc
```

Compare against host RAM, leaving room for QEMU overhead and the host itself.

Estimate real guest demand:

```
guest memory in use  =  AnonPages (in RAM)  +  KSM savings  +  sum of per-VM VmSwap
```

If that is close to or above host RAM, swap usage is the expected result of density, not a tuning fault. With `cache=none`, guests fill their own spare RAM with their own page cache, so over time they tend to touch everything they are allocated.

> On an overcommitted host, `available` in `free` is misleading. The cache is reclaimable, but it is not spare capacity for more guests.

---

#### 9. Fixes

#### Find and constrain the cache source

**When this applies**

Use this fix when sections 3 and 6 showed the pattern from the "Common patterns" table: a large page cache (mostly `Inactive(file)`) sitting alongside full or growing swap. If the cache is small, or swap is explained by one large process, skip this and go to the other fixes.

**Why a page cache problem turns into a swap problem**

Page cache is normally harmless. The kernel fills spare RAM with recently read and written file data and drops it when something needs the memory. The trouble comes from jobs that push a large amount of data through the cache in a short time. Common examples:

- backups that read whole disks, VM images, or database files
- `tar`, `rsync`, `cp`, or `dd` of large files
- `qemu-img convert`, snapshot exports, and migrations on a hypervisor
- log rotation and compression, `updatedb`, or antivirus scans walking the whole filesystem

These jobs read or write tens of GB once and never look at that data again, so the cache they create is useless. But while the job runs:

1. The cache grows faster than the kernel's background reclaim (`kswapd`) can free memory.
2. Free memory hits the low watermark, and the kernel has to reclaim from everything, not just the cache.
3. The freshly read file pages look recently used, while idle application memory (a quiet daemon, an idle VM's RAM) looks cold. So the kernel swaps out the application memory.
4. When the job ends, its cache sits there as `Inactive(file)` until something else needs the RAM. The swapped pages stay in swap until the application touches them again.

The result is the confusing picture of 100 GB of "available" memory and a full swap device. Lowering swappiness helps a little, but it has little say during these bursts (see section 10). Stopping the flood at its source is what actually fixes it.

**Step 1: Find which job it is**

Work out when the cache grows, then match that time to a job.

- **Use history.** `sar -r` shows `kbcached` over the day. A jump of tens of GB at the same time each night is a scheduled job.
- **Or reset and watch.** Run the drop-caches test from section 6, then check `free -h` periodically. Note when `buff/cache` jumps.
- **Match it against the schedule:**

  ```
  crontab -l; ls /etc/cron.d /etc/cron.daily
  systemctl list-timers --all
  ```

  On a control-panel host such as SolusVM, also check the panel's backup schedule.
- **Catch it in the act.** While the cache is growing, see who is doing the I/O:

  ```
  iotop -obPa            # processes doing the most I/O
  pidstat -d 5           # per-process read/write rates (sysstat)
  ```

- **Confirm what is cached.** `fincore` (section 3) on the files the job touches shows how much of them is sitting in RAM.

**Step 2: Stop the job filling the cache**

Pick whichever option suits the job. They are listed from most targeted to most general.

*Option A: Have the tool bypass the cache (direct I/O)*

Direct I/O reads and writes straight to disk without keeping a copy in the page cache. Use it when the tool supports it:

```
# dd: bypass the cache for both reading and writing
#   iflag=direct  read the source without caching it
#   oflag=direct  write the destination without caching it
dd if=/dev/vg0/vm-disk of=/backup/vm-disk.img bs=1M iflag=direct oflag=direct

# qemu-img: -t sets the destination cache mode, -T the source cache mode
qemu-img convert -t none -T none -O qcow2 source.img dest.qcow2
```

Two cautions with `qemu-img`:

- **Where `-T` goes matters.** Placed *after* `convert`, `-T` is the source cache mode. Placed *before* the subcommand (`qemu-img -T ... convert`), it is the global `--trace` option. The man page lists both, which is easy to misread.
- **Older versions lack the source option.** `-T SRC_CACHE` arrived in the QEMU 2.x series. The `qemu-img` 1.5.3 shipped with stock CentOS 7 does not have it. Check with `qemu-img --version` and `qemu-img --help | grep convert`. On older versions, use `-t none` for the destination only, and handle the source side with option B or C below.

Direct I/O needs a reasonable block size (`bs=1M` or larger) to perform well. Not every filesystem supports it (tmpfs, for example, does not).

*Option B: Wrap the job with `nocache`*

Most tools (`tar`, `rsync`, `cp`) have no direct I/O option. `nocache` is a small wrapper that tells the kernel to drop each file's cache once the program is done with it:

```
nocache tar czf /backup/site.tgz /var/www
nocache rsync -a /data/ /backup/data/
```

It is packaged on Debian and Ubuntu (`apt install nocache`). On RHEL-family systems you may need to build it from source. It does not work with statically linked programs.

*Option C: Run the job in a memory-limited cgroup*

This is the most general option, because it works for any job, including scripts that call many tools and backup agents you cannot change. A cgroup's memory accounting includes the page cache its processes create. When the job reaches its limit, the kernel reclaims that job's own cache instead of swapping other processes.

```
# cgroup v2 (most current distributions)
systemd-run --scope -p MemoryHigh=2G -p MemoryMax=4G /path/to/backup.sh

# cgroup v1 (older systems such as CentOS 7)
systemd-run --scope -p MemoryLimit=4G /path/to/backup.sh
```

- `MemoryHigh` is a soft limit. Above it, the kernel reclaims the job's cache aggressively and slows the job down, but does not kill it.
- `MemoryMax` (or `MemoryLimit` on v1) is a hard ceiling. If the job's own working memory, not cache, exceeds it, the job is killed. Set it well above what the job actually needs.
- To find out which cgroup version you are running: `stat -fc %T /sys/fs/cgroup` prints `cgroup2fs` for v2.

For a job that already runs as a systemd service or timer, put the limits in the unit instead:

```
systemctl edit backup.service
# then add:
[Service]
MemoryHigh=2G
MemoryMax=4G
```

For a cron job, put `systemd-run --scope ...` in front of the command in the crontab line.

Note that `nice` and `ionice` do not help here. They lower the job's CPU and disk priority but do nothing to the amount of cache it creates.

**Step 3: Check that it worked**

After the job's next run:

- `buff/cache` in `free -h` should rise by only a few GB at the job's start time, not tens of GB.
- `vmstat 1` during the run should show `so` at or near 0.
- `sar -S` (swap use over time) should stay flat instead of stepping up after each run.

Once that holds, it is safe to drain the existing swap (see "Drain the swap").

#### Lower swappiness

```
sysctl vm.swappiness=1
echo "vm.swappiness = 1" > /etc/sysctl.d/99-swappiness.conf
```

Use 1 rather than 0. This is a small lever, most useful on hypervisors and database hosts.

#### Fix NUMA imbalance

Only needed if `numastat -m` showed one node nearly full while another has free memory (see "Understanding NUMA" in section 5). If the nodes look similar, skip this.

**Turn off zone reclaim**

```
sysctl vm.zone_reclaim_mode=0
echo "vm.zone_reclaim_mode = 0" > /etc/sysctl.d/99-numa.conf
```

This lets the kernel take memory from another node instead of dropping cache and swapping on the full one. It takes effect immediately and does not need a reboot. The cost is that some processes get slower remote memory, which is almost always better than swapping.

**Loosen or rebalance pinning**

If processes or VMs are pinned to one node:

- Spread them across nodes so each node carries a similar share of memory.
- Where exact placement is not essential, use a softer policy: `numactl --preferred=<node>` instead of `--membind`, or libvirt `mode='preferred'` instead of `strict` (`virsh numatune <vm> --mode preferred --config`, applied on the VM's next full stop and start).
- Keep `strict` only for workloads that are sized to fit their node and genuinely need local memory.

**Let the kernel balance automatically**

```
cat /proc/sys/kernel/numa_balancing       # 1 = on
```

Automatic NUMA balancing moves processes and their memory closer together over time. It is on by default on most distributions and is best left on. It cannot override strict pinning.

**Check the result**

Re-run `numastat -m` after the change and again after normal load returns. Free memory should now be spread across nodes, and `vmstat` `so` should stay near 0 while either node still has room.

#### Drain the swap

Only after the cause is dealt with, otherwise it will refill.

```
swapoff -a && swapon -a
```

- Check first that `available` comfortably exceeds swap used (and on a KVM host, the sum of per-VM `VmSwap`).
- It can take from tens of minutes to hours and causes heavy I/O. Do it off-peak.
- Watch `free -h` and `vmstat 1` while it runs.
- With several swap devices, do one at a time: `swapoff /dev/X && swapon /dev/X`.
- On a KSM host, consider starting the scanner first: `echo 1 > /sys/kernel/mm/ksm/run`.

#### Address capacity

When the host is simply overcommitted:

- Move workloads or VMs off.
- Add RAM.
- If accepting the current density, add swap so there is a cushion before the OOM killer.

---

#### 10. What swappiness really does

Swappiness is a ratio, not a threshold. It does not mean "start swapping at X% usage."

When the kernel reclaims memory, it splits scan pressure between anonymous memory (must be swapped) and file cache (can be dropped):

- anon weight = swappiness
- file weight = 200 - swappiness

| Swappiness | Anon : file | Share aimed at anon |
|---|---|---|
| 60 (default) | 60 : 140 | 30% |
| 10 | 10 : 190 | 5% |
| 1 | 1 : 199 | 0.5% |
| 0 | Special case | Avoid swap until file cache is nearly gone |

The weights are then adjusted by how often recently reclaimed pages of each type were faulted back in.

The kernel ignores the ratio in some cases:

- Plenty of inactive file cache: reclaims file only.
- File cache nearly exhausted: reclaims anon regardless.
- Severe pressure: scans everything.

So swappiness only matters in the middle ground, and it has little say during bursts where memory fills faster than reclaim can keep up. That is how a host can end up with full swap at a low swappiness setting.

Setting 0 can lead to OOM kills while swap sits unused. 1 is the lowest value that keeps swap working as a safety valve.

The exact heuristics vary by kernel version.

---

#### 11. Quick collection script

Gathers everything above into one file for review.

```bash
#!/bin/bash
out=swap-diag-$(hostname -s)-$(date +%Y%m%d-%H%M).txt
{
  echo "### uname";      uname -r
  echo "### free";       free -h
  echo "### vmstat";     vmstat 1 10
  echo "### psi";        cat /proc/pressure/memory 2>/dev/null
  echo "### meminfo";    cat /proc/meminfo
  echo "### sysctl";     sysctl vm.swappiness vm.min_free_kbytes vm.zone_reclaim_mode vm.overcommit_memory
  echo "### swapon";     swapon --show
  echo "### numastat";   numastat -m 2>/dev/null
  echo "### thp";        cat /sys/kernel/mm/transparent_hugepage/enabled
  echo "### tmpfs";      df -h -t tmpfs
  echo "### top rss";    ps -eo pid,user,rss,vsz,comm --sort=-rss | head -20
  echo "### top swap"
  for f in /proc/[0-9]*/status; do
    awk '/^Name/{n=$2} /^Pid/{p=$2} /^VmSwap/{if($2>0) print $2, p, n}' $f
  done 2>/dev/null | sort -n | tail -20
  echo "### slab";       slabtop -o 2>/dev/null | head -20
  echo "### oom";        dmesg -T 2>/dev/null | grep -iE "oom|out of memory" | tail -20
  echo "### ksm";        grep . /sys/kernel/mm/ksm/{run,pages_shared,pages_sharing} 2>/dev/null
  echo "### timers";     systemctl list-timers --all 2>/dev/null
} > "$out" 2>&1
echo "Wrote $out"
```

Run as root so every process's swap figure is readable.