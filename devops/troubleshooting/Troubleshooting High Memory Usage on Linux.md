#### Troubleshooting High Memory Usage on Linux

A practical guide for working out what is using memory on a Linux host, whether it is a problem, and what to do about it. Covers general bare-metal servers first, then the extra checks for KVM/QEMU hypervisors. Companion to the swap troubleshooting guide.

#### Contents

1. [Is memory actually high?](#1-is-memory-actually-high)
2. [Is it causing problems?](#2-is-it-causing-problems)
3. [Break memory down by category](#3-break-memory-down-by-category)
4. [Process memory](#4-process-memory)
5. [Reading memory usage of a single process](#5-reading-memory-usage-of-a-single-process)
6. [Is something growing?](#6-is-something-growing)
7. [Page cache and tmpfs](#7-page-cache-and-tmpfs)
8. [Kernel memory](#8-kernel-memory)
9. [cgroups and containers](#9-cgroups-and-containers)
10. [NUMA](#10-numa)
11. [Reading an OOM kill](#11-reading-an-oom-kill)
12. [Common patterns](#12-common-patterns)
13. [KVM / QEMU hypervisors](#13-kvm--qemu-hypervisors)
14. [Fixes](#14-fixes)
15. [Quick collection script](#15-quick-collection-script)

---

#### 1. Is memory actually high?

```
free -h
```

| Column | Meaning |
|---|---|
| `used` | Memory held by processes and the kernel, excluding cache |
| `free` | Completely unused memory. Being near zero is normal |
| `shared` | tmpfs and shared memory (`Shmem`) |
| `buff/cache` | Page cache, buffers, and reclaimable slab |
| `available` | Estimate of what could be handed to applications without swapping |

Key points:

- **Low `free` is not high memory usage.** Linux fills spare RAM with cache on purpose and gives it back on demand.
- **`available` is the number to judge by.** Below roughly 10% of total, the host is tight. Near zero, expect swapping or OOM kills.
- `available` is an estimate. It can overstate what is usable when `shared` is large (tmpfs counts as cache but cannot be dropped) or when the host is overcommitted.
- Many monitoring tools alert on `used + buff/cache`. Check what your graph is measuring before chasing a non-problem.

---

#### 2. Is it causing problems?

```
vmstat 1 10
cat /proc/pressure/memory                       # kernel 4.20+ (or backported)
dmesg -T | grep -iE "oom|out of memory" | tail
sar -B 1 5                                      # needs sysstat
```

| Signal | Healthy | Problem |
|---|---|---|
| `available` in `free` | Comfortable margin | Near zero |
| `vmstat` `si` / `so` | 0 | Sustained non-zero: active swapping |
| PSI `some avg10` | Near 0 | Above a few percent: tasks stalling on memory |
| PSI `full avg10` | 0 | Anything above 0: everything stalled at times |
| `sar -B` `pgscand/s` | 0 | Non-zero: direct reclaim, processes stalled to free memory |
| OOM messages | None | Any: the host has already run out |

If none of these show trouble, memory is well used, not over-used. The rest of this guide is still useful for capacity planning.

---

#### 3. Break memory down by category

```
cat /proc/meminfo
```

Every page of RAM belongs to one of a few categories. Roughly:

```
MemTotal  ~=  MemFree
            + AnonPages                     (process heap and stack)
            + Cached + Buffers              (page cache; Cached includes Shmem)
            + Slab                          (SReclaimable + SUnreclaim)
            + PageTables + KernelStack
            + HugePages_Total x Hugepagesize
            + unaccounted                   (drivers, ZFS ARC, vmalloc, etc.)
```

| Field | What it is | If it is the big one |
|---|---|---|
| `AnonPages` | Process private memory | Section 4: find the process |
| `Cached` minus `Shmem` | File page cache | Usually fine. Section 7 |
| `Shmem` | tmpfs files and shared memory segments | Section 7. Not droppable |
| `SReclaimable` | Dentry and inode caches | Usually fine. Section 8 |
| `SUnreclaim` | Kernel slab that cannot be freed | Section 8: possible kernel leak |
| `PageTables` | Memory mapping overhead | Many processes mapping large shared memory. Use hugepages |
| `HugePages_Total` | Reserved hugepages | Reserved whether used or not. Compare with `HugePages_Free` |
| `Mlocked` | Memory pinned in RAM | Check which process locked it |
| `Committed_AS` vs `CommitLimit` | Memory promised vs what exists | Shows overcommit, not current use |

The quickest way to decide where to look:

```
awk '/^(MemTotal|MemFree|MemAvailable|AnonPages|Cached|Buffers|Shmem|Slab|SReclaimable|SUnreclaim|PageTables|KernelStack|HugePages_Total|Hugepagesize|VmallocUsed):/ {printf "%-18s %8.1f GiB\n", $1, ($1 ~ /HugePages_Total/ ? $2 : $2/1048576)}' /proc/meminfo
```

(`HugePages_Total` prints as a page count. Multiply by `Hugepagesize`.)

If the categories fall well short of `MemTotal`, see "Missing memory" in section 8.

---

#### 4. Process memory

Start here when `AnonPages` is the large category.

```
# Largest by resident memory
ps -eo pid,user,rss,vsz,pmem,etime,comm --sort=-rss | head -20

# Totals grouped by program name (MiB)
ps -eo rss,comm --no-headers | awk '{a[$2]+=$1} END {for (c in a) printf "%8.0f MiB  %s\n", a[c]/1024, c}' | sort -rn | head -20

# Accurate, shared memory split fairly (if installed)
smem -rs pss | head -20
```

Know which number you are reading:

| Metric | Meaning | Use it for |
|---|---|---|
| VSZ / VIRT | Address space reserved | Almost nothing. Often huge and harmless |
| RSS / RES | Pages in RAM, including shared ones | Quick ranking. Double-counts shared memory |
| PSS | RSS with shared pages divided among sharers | Honest per-process totals |
| USS | Pages unique to the process | What you get back if you kill it |

RSS traps:

- Processes sharing a large segment (PostgreSQL `shared_buffers`, Oracle SGA, forked workers) each report it in full. Summing RSS can exceed total RAM.
- Many small processes can outweigh one big one. Always check the grouped totals.

To dig into one process, see section 5.

---

#### 5. Reading memory usage of a single process

Once you have a suspect PID, these are the places to read its memory from, in increasing detail. Reading another user's process needs root.

**Quick view**

```
ps -o pid,user,rss,vsz,pmem,nlwp,etime,cmd -p <pid>
top -p <pid>
pidstat -r -p <pid> 5                 # needs sysstat: RSS and page faults over time
```

In `top`: `VIRT` is address space, `RES` is RSS, and `SHR` is the part of RES that is file-backed or shared memory. `RES - SHR` is roughly the process's own anonymous memory.

**Summary: `/proc/<pid>/status`**

```
grep -E "^(Vm|Rss|HugetlbPages|Threads)" /proc/<pid>/status
```

| Field | Meaning |
|---|---|
| `VmSize` | Address space reserved (VSZ). Not memory in use |
| `VmPeak` | Highest `VmSize` has been |
| `VmRSS` | Pages in RAM now. Equals `RssAnon + RssFile + RssShmem` |
| `VmHWM` | Highest `VmRSS` has been ("high water mark") |
| `RssAnon` | Heap, stack, and other private anonymous memory |
| `RssFile` | Mapped files: binaries, libraries, mmap'd data. Reclaimable |
| `RssShmem` | Shared memory and tmpfs mappings |
| `VmData` | Size of data and heap mappings (virtual) |
| `VmStk` | Main thread stack |
| `VmExe`, `VmLib` | Program text and shared libraries (virtual) |
| `VmPTE` | Page tables for this process |
| `VmSwap` | Anonymous memory currently in swap. Not included in RSS |
| `VmLck`, `VmPin` | Locked or pinned memory that cannot be swapped |
| `HugetlbPages` | Explicit hugepages in use. Not included in RSS |
| `Threads` | Thread count |

The process's real footprint is roughly `VmRSS + VmSwap + HugetlbPages`.

**Accurate totals: `/proc/<pid>/smaps_rollup`**

```
cat /proc/<pid>/smaps_rollup          # kernel 4.14+
```

| Field | Meaning |
|---|---|
| `Rss` | Same as `VmRSS` |
| `Pss` | RSS with each shared page divided by the number of processes sharing it |
| `Pss_Anon`, `Pss_File`, `Pss_Shmem` | PSS split by type (kernel 5.4+) |
| `Private_Clean` + `Private_Dirty` | USS: memory only this process uses. What you get back if it exits |
| `Shared_Clean` + `Shared_Dirty` | Pages also mapped by other processes |
| `Anonymous` | Anonymous pages in RAM |
| `AnonHugePages` | Portion backed by transparent hugepages |
| `Swap` | Swapped-out memory |
| `SwapPss` | Swap with shared pages divided among sharers |
| `Locked` | Memory locked in RAM |

On older kernels, sum the full `smaps` file instead:

```
awk '/^(Rss|Pss|Private_Clean|Private_Dirty|Swap):/{a[$1]+=$2} END {for (k in a) printf "%-15s %10.1f MiB\n", k, a[k]/1024}' /proc/<pid>/smaps
```

**Where inside the process: mappings**

```
pmap -x <pid> | sort -k3 -n | tail -20        # largest mappings by RSS
```

Or from `smaps`, which also shows swap per mapping:

```
awk '/^[0-9a-f]+-[0-9a-f]+ /{name=($6==""?"[anon]":$6)} /^Rss:/{r[name]+=$2} /^Swap:/{s[name]+=$2} END {for (n in r) printf "%10.1f MiB rss %10.1f MiB swap  %s\n", r[n]/1024, s[n]/1024, n}' /proc/<pid>/smaps | sort -n | tail -20
```

| Mapping | What it is |
|---|---|
| `[heap]` | The main malloc heap (brk) |
| `[anon]` / blank | Anonymous mmap: large allocations, thread stacks, allocator arenas, JVM heap |
| `[stack]` | Main thread stack |
| A file path | Binary, library, or a memory-mapped data file |
| `/dev/shm/...`, `/SYSV...`, `/memfd:...` | Shared memory |
| `/dev/hugepages/...`, `/anon_hugepage` | Hugepage-backed memory |

Clues in the mapping list:

- **Many anonymous regions of about 64 MB** (often 132 KB used plus the rest reserved): glibc malloc arenas, one per thread. Points to arena fragmentation.
- **One very large anonymous region**: a pre-sized pool such as a JVM heap or database buffer.
- **Many regions of 8 MB or so**: thread stacks. Mostly virtual, little RSS.
- **A large mapped data file**: counted in RSS but reclaimable, like page cache.

**Threads and child processes**

- Threads share one address space. `ps -L` and `htop` (which shows threads by default) list the same RSS on every thread line. Do not add them up.
- For a service made of several processes, add up PSS, not RSS:

```
# Total PSS for a process and its descendants, in MiB
for p in <pid> $(pgrep -P <pid>); do awk '/^Pss:/{print $2}' /proc/$p/smaps_rollup; done | paste -sd+ | bc | awk '{printf "%.1f MiB\n", $1/1024}'

# Or for a whole systemd unit
systemctl show <unit> -p MemoryCurrent
```

(`pgrep -P` lists direct children only. For deeper trees, use the unit or cgroup figure.)

**Its cgroup and OOM standing**

```
cat /proc/<pid>/cgroup                # which cgroup it is in
cat /proc/<pid>/oom_score             # higher = killed sooner
```

The cgroup's `memory.current` includes page cache charged to the group, so it is usually higher than the sum of process PSS.

**How to read the result**

| What you see | Meaning |
|---|---|
| `VmSize` huge, `VmRSS` small | Reserved but unused address space. Harmless |
| `VmRSS` mostly `RssAnon` | Heap. Check whether it is growing (section 6) |
| `VmRSS` mostly `RssShmem` | A shared segment. Counted in every process that maps it |
| `VmRSS` mostly `RssFile` | Mapped files. Reclaimable under pressure |
| `Rss` far above `Pss` | Mostly shared memory. The process is smaller than it looks |
| `VmRSS` small, `VmSwap` large | Mostly swapped out. Real footprint is the sum |
| `VmHWM` far above `VmRSS` | It was bigger earlier and gave memory back, or was swapped |
| `RssAnon` far above what the app reports (heap size, cache size) | Allocator fragmentation or native allocations outside the app's own accounting |
| `AnonHugePages` close to `RssAnon` | THP in use. Can inflate RSS for sparse allocations |
| `VmPTE` hundreds of MB | Very large mappings with 4 KB pages. Hugepages would cut it |

---

#### 6. Is something growing?

A single snapshot cannot tell a leak from a large but stable footprint. Sample over time.

```
# One process
while sleep 60; do
  echo "$(date +%T) $(awk '/VmRSS|VmSwap/{printf "%s %s kB  ", $1, $2}' /proc/<pid>/status)"
done

# Whole system categories
while sleep 60; do
  echo "$(date +%T) $(awk '/^(MemAvailable|AnonPages|Shmem|SUnreclaim):/{printf "%s %s  ", $1, $2}' /proc/meminfo)"
done

# History, if sysstat is collecting
sar -r
```

| Shape | Likely meaning |
|---|---|
| Climbs steadily, never drops, resets on restart | Leak |
| Climbs then plateaus | Cache or buffer pool warming up. Normal |
| Steps up at fixed times | Scheduled job |
| Follows traffic, does not come back down | Allocator fragmentation or retained pools |

For a suspected leak in a specific program:

- **JVM**: compare heap (`jcmd <pid> GC.heap_info`) with RSS. If RSS far exceeds `-Xmx`, look at native memory (`-XX:NativeMemoryTracking=summary`, then `jcmd <pid> VM.native_memory`).
- **glibc malloc**: many threads create many arenas and fragmentation. Try `MALLOC_ARENA_MAX=2` or a different allocator (jemalloc, tcmalloc).
- **Native code**: `heaptrack`, `valgrind --tool=massif`, or `memleak` from bcc-tools on a live process.
- **Python, Node, Ruby, PHP**: usually application-level object retention. Worker recycling (max requests per worker) is the common mitigation.

---

#### 7. Page cache and tmpfs

File cache is reclaimable and normally not a problem. It becomes relevant when it crowds out other things or when part of it is not really reclaimable.

```
grep -E "^(Cached|Buffers|Shmem|Active\(file\)|Inactive\(file\)|Dirty|Writeback|Mapped):" /proc/meminfo
df -h -t tmpfs -t devtmpfs
ipcs -m                                  # System V shared memory
ls -la /dev/shm | head
```

- **`Shmem` is the catch.** Files in `/dev/shm`, `/run`, `/tmp` (when tmpfs), and shared memory segments are counted as cache but can only be freed by deleting them or swapping. A large `shared` column in `free` means "available" is overstated.
- **Large `Dirty` or `Writeback`**: slow storage is not keeping up with writes. Memory is tied up until the data reaches disk.
- **Orphaned shared memory**: `ipcs -m` segments with `nattch` 0 belong to no running process. Remove with `ipcrm -m <id>` once you are sure.

To see which files are cached:

```
# util-linux 2.30+
find /path/to/suspect/dir -xdev -type f -size +1G 2>/dev/null | xargs fincore 2>/dev/null | sort -k1 -h | tail -20
```

To test whether cache is truly reclaimable:

```
sync; echo 1 > /proc/sys/vm/drop_caches     # page cache only
```

Safe, but reads will be slower until the cache warms up. Whatever remains in `Cached` afterwards is mostly `Shmem` and mapped files.

---

#### 8. Kernel memory

```
slabtop -o -s c | head -25                   # slab caches, largest first
grep -E "^(Slab|SReclaimable|SUnreclaim|PageTables|KernelStack|VmallocUsed|Percpu):" /proc/meminfo
```

| Finding | Meaning |
|---|---|
| `dentry`, `inode_cache`, `ext4_inode_cache`, `xfs_inode` large | Filesystem metadata cache. Reclaimable. Grows with many files walked (backups, `find`, `updatedb`) |
| `SUnreclaim` many GB and growing | Kernel or driver leak. Note the top cache in `slabtop` and search it against your kernel version |
| `kmalloc-*` caches growing | Often a driver or module leak |
| `PageTables` many GB | Many processes mapping large shared memory with 4 KB pages. Use hugepages for the shared region |
| `KernelStack` large | Very high thread count. Check `ps -eLf \| wc -l` |

To test whether slab is reclaimable:

```
sync; echo 2 > /proc/sys/vm/drop_caches     # dentries and inodes
```

If dentry and inode caches regularly grow too large, raising `vm.vfs_cache_pressure` above 100 makes the kernel reclaim them more eagerly.

**Hugepages**

```
grep -i huge /proc/meminfo
cat /sys/kernel/mm/transparent_hugepage/enabled
```

- `HugePages_Total x Hugepagesize` is reserved and counted as used whether anything uses it. If `HugePages_Free` is most of the total, the reservation is wasted. Lower `vm.nr_hugepages`.
- Transparent hugepages can inflate RSS for sparse allocations. If a process's RSS dropped after setting THP to `madvise`, that was the cause.

**Missing memory**

When `used` is high but processes, cache, and slab do not account for it:

| Suspect | Check |
|---|---|
| ZFS ARC | `arc_summary` or `awk '/^size/{print $3/1073741824 " GiB"}' /proc/spl/kstat/zfs/arcstats`. Cap with `zfs_arc_max` |
| Reserved hugepages | `grep HugePages /proc/meminfo` |
| VM balloon driver (when the box is itself a guest) | `lsmod \| grep -E "balloon\|vmw"`. The hypervisor has taken memory back |
| GPU, NIC, or RDMA drivers | Large ring buffers and pinned pages. `ethtool -g <nic>` |
| vmalloc | `VmallocUsed`, and `sort -k2 -n /proc/vmallocinfo \| tail` |
| Kernel leak | Unaccounted amount grows with uptime and only a reboot clears it |

---

#### 9. cgroups and containers

A service or container with a memory limit can be out of memory while the host has plenty, and host-level tools will look healthy.

```
systemd-cgtop -m                                    # live, by memory
systemctl show <unit> -p MemoryCurrent -p MemoryMax -p MemoryHigh
docker stats --no-stream                            # or: crictl stats, kubectl top pod
```

cgroup v2 files, under `/sys/fs/cgroup/<path>/`:

| File | Meaning |
|---|---|
| `memory.current` | Usage now, including page cache charged to the group |
| `memory.max` | Hard limit. Hitting it triggers reclaim, then an OOM kill inside the group |
| `memory.high` | Soft limit. Above it the group is throttled and reclaimed |
| `memory.stat` | Breakdown: `anon`, `file`, `shmem`, `slab`, and others |
| `memory.events` | Counters for `high`, `max`, `oom`, `oom_kill` |

cgroup v1 equivalents: `memory.usage_in_bytes`, `memory.limit_in_bytes`, `memory.failcnt`, `memory.stat`.

Notes:

- Container usage includes page cache. A container "at its limit" may be mostly cache, which is fine, or mostly `anon`, which is not. Read `memory.stat`.
- A non-zero `oom_kill` in `memory.events` (or rising `failcnt` on v1) confirms kills caused by the limit, not by the host.
- Inside a container, `free` and `/proc/meminfo` usually show the host's numbers. Trust the cgroup files.

---

#### 10. NUMA

On multi-socket machines, one node can be exhausted while another has room.

```
numastat -m                    # per-node breakdown
numastat -p <pid>              # where a process's memory sits
sysctl vm.zone_reclaim_mode
```

- One node near zero free while the other is fine: pinned workloads, or a large process started when one node was already full.
- `vm.zone_reclaim_mode` non-zero forces a node to reclaim locally before using another node. Usually should be 0.

---

#### 11. Reading an OOM kill

```
dmesg -T | grep -iE -B5 -A40 "invoked oom-killer"
journalctl -k --since "2 days ago" | grep -iE "oom|killed process"
```

What to pull out of the report:

| Line | Tells you |
|---|---|
| `<name> invoked oom-killer` | The process that asked for memory at the wrong moment. Often not the culprit |
| `gfp_mask`, `order` | Kind and size of the request. `order` above 0 with free memory present suggests fragmentation |
| `constraint=CONSTRAINT_MEMCG` or `Memory cgroup out of memory` | A cgroup limit was hit, not host exhaustion |
| `Mem-Info` block | Per-zone and per-node state at the time: `active_anon`, `slab_unreclaimable`, `shmem`, free swap |
| Process table (`rss` column, in pages) | Who was large at that moment. Multiply by 4 for KB |
| `Killed process <pid> (<name>) total-vm, anon-rss, file-rss, shmem-rss` | The victim and its size |

Common misreadings:

- The victim is chosen by score (roughly its share of memory), so it is the largest process, not necessarily the one that grew.
- If the process table adds up to far less than RAM, the memory was in the kernel, tmpfs, or hugepages. Go back to section 8.

To see or adjust who gets killed first:

```
cat /proc/<pid>/oom_score
echo -500 > /proc/<pid>/oom_score_adj      # -1000 (never) to 1000 (first)
```

---

#### 12. Common patterns

| Pattern | Likely cause |
|---|---|
| `available` healthy, `free` near zero | Normal. Page cache doing its job |
| High `AnonPages`, one large process, growing | Leak |
| High `AnonPages`, one large process, flat | Configured size (JVM heap, database buffers). Tune or accept |
| High `AnonPages`, many mid-sized processes | Too many workers for the RAM |
| RSS totals exceed RAM | Shared memory double-counted. Use PSS |
| High `Shmem` | tmpfs files or leftover shared memory segments |
| High `SReclaimable` | Dentry and inode cache after walking many files |
| High `SUnreclaim`, growing with uptime | Kernel or driver leak |
| High `PageTables` | Large shared memory mapped by many processes without hugepages |
| Used is high, nothing accounts for it | ZFS ARC, hugepage reservation, balloon driver, or a kernel leak |
| Host fine, one service getting killed | cgroup memory limit |
| One NUMA node empty | Pinning or `zone_reclaim_mode` |
| OOM kills with swap unused | `swappiness=0`, mlocked memory, or a cgroup limit without swap |

---

#### 13. KVM / QEMU hypervisors

Guest RAM is anonymous memory inside each QEMU process, so a hypervisor normally shows high `AnonPages` and that is expected. The questions are how much is allocated, how much is really backed, and what is helping it fit.

**Allocated vs host RAM**

```
# Total RAM allocated to running guests, in KiB
for v in $(virsh list --name); do virsh dominfo $v | awk '/Max memory/{print $3}'; done | paste -sd+ | bc
```

Leave room for QEMU overhead (a few hundred MB per guest, more with many devices) and the host itself.

**Actual footprint per guest**

```
for p in $(pgrep -f qemu); do
  printf "%8.1f GiB RSS  %6.1f GiB swap  %s\n" \
    "$(awk '/VmRSS/{print $2/1048576}' /proc/$p/status)" \
    "$(awk '/VmSwap/{print $2/1048576}' /proc/$p/status)" \
    "$(tr '\0' ' ' < /proc/$p/cmdline | grep -o 'guest=[^, ]*')"
done | sort -n
```

- Guests tend to touch all of their allocated RAM over time, because each guest fills its own spare memory with its own page cache. To the host that is all in-use anonymous memory.
- A QEMU process well above its guest's allocation points to overhead or a leak in QEMU itself.

**What is helping it fit**

| Mechanism | Check | Caveat |
|---|---|---|
| KSM | `grep . /sys/kernel/mm/ksm/{run,pages_shared,pages_sharing}`. Saved memory = `pages_sharing` x 4 KB | Savings shrink when guests reboot or change workload |
| Ballooning | `virsh dommemstat <vm>`: compare `actual` with `rss`, and see `unused` / `usable` inside the guest | Needs the balloon driver in the guest |
| Swap | Per-VM `VmSwap` above | A full swap device leaves no cushion |
| Hugepages | `grep -c hugepages /etc/libvirt/qemu/*.xml` | Hugepage-backed guests cannot be swapped or merged by KSM |

**Host page cache**

With `cache=none` on guest disks, the host should have little page cache. A large host cache on a hypervisor means either a different cache mode (`virsh dumpxml <vm> | grep cache`) or host-side jobs such as backups reading images through the cache.

> On an overcommitted hypervisor, `available` is misleading. Cache is reclaimable, but it is not spare capacity for more guests.

---

#### 14. Fixes

Match the fix to the category that turned out to be large.

**A process is too big or leaking**

- Restart it for immediate relief, then fix or mitigate the cause.
- Tune configured sizes: JVM `-Xmx`, database buffer pools, worker and connection counts.
- Recycle workers after a fixed number of requests.
- Contain it so it cannot take the host down:

```
systemctl set-property <unit> MemoryHigh=6G MemoryMax=8G     # cgroup v2
systemctl set-property <unit> MemoryLimit=8G                 # cgroup v1
```

**tmpfs or shared memory**

- Delete stale files in `/dev/shm`, `/run`, `/tmp`.
- Remove orphaned segments with `ipcrm -m <id>`.
- Cap tmpfs mounts with a `size=` option.

**Kernel caches**

```
sysctl vm.vfs_cache_pressure=200          # reclaim dentry and inode caches more eagerly
```

- For ZFS, set `zfs_arc_max`.
- For a real slab leak, the fix is a kernel or driver update. A reboot is the workaround.

**Hugepages**

```
sysctl vm.nr_hugepages=<needed>           # release unused reservation
```

**Avoiding stalls and hard OOMs**

- Raise `vm.min_free_kbytes` modestly on large hosts so reclaim starts earlier (too high wastes RAM).
- Run `systemd-oomd` or `earlyoom` to kill the right thing early instead of letting the box thrash.
- Protect critical processes with `oom_score_adj`.
- Keep some swap. It gives reclaim room to work and makes OOM behaviour more gradual.

**Capacity**

When usage is legitimate and stable:

- Move workloads off.
- Add RAM.
- Lower per-service footprints to match what the host has.

---

#### 15. Quick collection script

Gathers everything above into one file for review.

```bash
#!/bin/bash
out=mem-diag-$(hostname -s)-$(date +%Y%m%d-%H%M).txt
{
  echo "### uname";       uname -r; uptime
  echo "### free";        free -h
  echo "### vmstat";      vmstat 1 5
  echo "### psi";         cat /proc/pressure/memory 2>/dev/null
  echo "### meminfo";     cat /proc/meminfo
  echo "### top rss";     ps -eo pid,user,rss,vsz,pmem,etime,comm --sort=-rss | head -25
  echo "### rss by name"
  ps -eo rss,comm --no-headers | awk '{a[$2]+=$1} END {for (c in a) printf "%8.0f MiB  %s\n", a[c]/1024, c}' | sort -rn | head -20
  echo "### threads";     ps -eLf --no-headers | wc -l
  echo "### tmpfs";       df -h -t tmpfs -t devtmpfs
  echo "### sysv shm";    ipcs -m
  echo "### slab";        slabtop -o -s c 2>/dev/null | head -25
  echo "### hugepages";   grep -i huge /proc/meminfo; cat /sys/kernel/mm/transparent_hugepage/enabled
  echo "### zfs arc";     awk '/^(size|c_max)/{print $1, $3/1073741824 " GiB"}' /proc/spl/kstat/zfs/arcstats 2>/dev/null
  echo "### numastat";    numastat -m 2>/dev/null
  echo "### sysctl";      sysctl vm.swappiness vm.min_free_kbytes vm.zone_reclaim_mode vm.overcommit_memory vm.vfs_cache_pressure vm.nr_hugepages
  echo "### cgroups";     systemd-cgtop -m -b -n 1 2>/dev/null | head -25
  echo "### swapon";      swapon --show
  echo "### ksm";         grep . /sys/kernel/mm/ksm/{run,pages_shared,pages_sharing} 2>/dev/null
  echo "### oom";         dmesg -T 2>/dev/null | grep -iE "oom|out of memory|killed process" | tail -30
} > "$out" 2>&1
echo "Wrote $out"
```

Run as root so every process and the kernel log are readable.