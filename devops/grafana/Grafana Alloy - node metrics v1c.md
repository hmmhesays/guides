# Node Exporter Core & Network Metrics Reference

This reference guide summarizes key system and network metrics exposed by Prometheus Node Exporter (and collected via Grafana Alloy) along with corresponding PromQL queries for dashboard graphing, alerting, and metric filtering.

> **Note on PromQL Rate Intervals:**
> All rate queries use Grafana's dynamic `$__rate_interval` variable, which is calculated from the **Scrape interval** set on the Prometheus data source in Grafana. For it to avoid graph breaks or missing data points, that setting must match the real scrape interval (for example `60s` for Alloy's default). If the data source is left at Grafana's 15s default while Alloy scrapes every 60s, rate windows can be too short and graphs will show gaps.

> **Note on graphing vs. alerting:**
> Queries ending in `> 0` filter out healthy (zero) series. Use that form for alert rules. For dashboard panels, drop the `> 0` so healthy hosts show a flat zero line instead of "No data".

## 1. Network Interface Layer (Layer 2 / Hardware & Driver)

Tracks physical interface errors, throughput, packet rates, and kernel ring buffer drops.

| Metric Name | Focus Area | Description / Cause of Spikes |
| ----- | ----- | ----- |
| <span style="white-space: nowrap;">node_network_receive_errs_total</span> | <span style="white-space: nowrap;">L2 / NIC Rx</span> | Corrupted incoming frames, physical layer faults (cables, SFPs), or duplex mismatches. |
| <span style="white-space: nowrap;">node_network_transmit_errs_total</span> | <span style="white-space: nowrap;">L2 / NIC Tx</span> | Hardware/driver transmission failures or physical link issues during sending. |
| <span style="white-space: nowrap;">node_network_receive_drop_total</span> | <span style="white-space: nowrap;">Kernel Rx Ring</span> | Hardware ring buffer full; CPU unable to process network interrupts fast enough. |
| <span style="white-space: nowrap;">node_network_transmit_drop_total</span> | <span style="white-space: nowrap;">Kernel Tx Queue</span> | Interface transmit queue (`txqueuelen`) full due to link saturation or throttled egress traffic. |
| <span style="white-space: nowrap;">node_network_receive_bytes_total</span> | <span style="white-space: nowrap;">Throughput Rx</span> | Total network bytes received across network interfaces. |
| <span style="white-space: nowrap;">node_network_transmit_bytes_total</span> | <span style="white-space: nowrap;">Throughput Tx</span> | Total network bytes transmitted across network interfaces. |
| <span style="white-space: nowrap;">node_network_receive_packets_total</span> | <span style="white-space: nowrap;">Packet Rate Rx</span> | Total network packets received. Used to compute average packet size or spot SYN floods. |
| <span style="white-space: nowrap;">node_network_transmit_packets_total</span> | <span style="white-space: nowrap;">Packet Rate Tx</span> | Total network packets transmitted. |

### PromQL Queries

* **Receive Error Rate (per second, per device):**

  ```
  rate(node_network_receive_errs_total[$__rate_interval])
  ```

* **Transmit Error Rate (per second, per device):**

  ```
  rate(node_network_transmit_errs_total[$__rate_interval])
  ```

  For alerting, append `> 0` to either query.

* **Combined Interface Drop Rate (Rx + Tx, per device):**

  ```
  sum by (instance, device) (rate(node_network_receive_drop_total[$__rate_interval]))
  +
  sum by (instance, device) (rate(node_network_transmit_drop_total[$__rate_interval]))
  ```

* **Network Bandwidth (bits/sec Rx/Tx per device):**

  ```
  rate(node_network_receive_bytes_total{device!="lo"}[$__rate_interval]) * 8
  rate(node_network_transmit_bytes_total{device!="lo"}[$__rate_interval]) * 8
  ```

  Set the Grafana panel unit to `bits/sec (SI)` and it will display Kbps/Mbps/Gbps automatically. If you need a fixed Mbps number (for alert thresholds), divide by `1000 / 1000`, not `1024 / 1024`: network Mbps is decimal, and 1024 gives Mibps, which reads about 5% low.

* **Average Packet Size (Bytes per Packet Rx):**

  ```
  rate(node_network_receive_bytes_total[$__rate_interval]) / rate(node_network_receive_packets_total[$__rate_interval])
  ```

## 2. Protocol & Transport Layer (TCP / UDP)

Reflects corrupt or unroutable transport-layer packets received by the host.

| Metric Name | Focus Area | Description / Cause of Spikes |
| ----- | ----- | ----- |
| <span style="white-space: nowrap;">node_netstat_Tcp_InErrs</span> | <span style="white-space: nowrap;">TCP Transport</span> | Inbound TCP segments dropped due to bad checksums or bad headers. |
| <span style="white-space: nowrap;">node_netstat_Udp_InErrors</span> | <span style="white-space: nowrap;">UDP Transport</span> | UDP datagrams the stack could not deliver. Includes bad checksums **and** receive buffer overflows, so it also rises whenever `Udp_RcvbufErrors` does. |
| <span style="white-space: nowrap;">node_netstat_Udp_NoPorts</span> | <span style="white-space: nowrap;">UDP Routing</span> | Incoming UDP packets delivered to a port without an active listening socket. |
| <span style="white-space: nowrap;">node_netstat_Udp_RcvbufErrors</span> | <span style="white-space: nowrap;">UDP OS Buffers</span> | UDP socket receive buffer full; application is reading too slowly from its socket. |

### PromQL Queries

* **Inbound Transport Layer Error Rate (TCP and UDP as separate series):**

  ```
  rate(node_netstat_Tcp_InErrs[$__rate_interval])
  rate(node_netstat_Udp_InErrors[$__rate_interval])
  ```

  Keep these as two series rather than adding them, so you can tell which protocol is erroring. Because `Udp_InErrors` includes buffer overflows, a rise here with a matching rise in `Udp_RcvbufErrors` points to a slow application, not corrupt packets.

* **UDP No-Port Drops Rate:**

  ```
  rate(node_netstat_Udp_NoPorts[$__rate_interval])
  ```

* **UDP Receive Buffer Overflow Rate:**

  ```
  rate(node_netstat_Udp_RcvbufErrors[$__rate_interval])
  ```

## 3. TCP Reliability, Socket Backlogs & Socket States

Indicates network congestion, path loss, application socket exhaustion, or connection leaks.

| Metric Name | Focus Area | Description / Cause of Spikes |
| ----- | ----- | ----- |
| <span style="white-space: nowrap;">node_netstat_Tcp_RetransSegs</span> | <span style="white-space: nowrap;">TCP Reliability</span> | Network packet loss, congestion, or firewall silently dropping packets along the path. |
| <span style="white-space: nowrap;">node_netstat_Tcp_OutSegs</span> | <span style="white-space: nowrap;">TCP Reliability</span> | Total TCP segments sent. Denominator for the retransmission percentage. |
| <span style="white-space: nowrap;">node_netstat_TcpExt_TCPSynRetrans</span> | <span style="white-space: nowrap;">Connection Setup</span> | Initial TCP `SYN` lost; handshake retry due to network loss or SYN flood attacks. |
| <span style="white-space: nowrap;">node_netstat_TcpExt_ListenOverflows</span> | <span style="white-space: nowrap;">Socket Backlog</span> | Application accept queue (`listen()` backlog) full; the application isn't calling `accept()` fast enough. |
| <span style="white-space: nowrap;">node_netstat_TcpExt_ListenDrops</span> | <span style="white-space: nowrap;">Socket Backlog</span> | All connection attempts dropped at a listening socket. A superset of `ListenOverflows` that also counts other drops (e.g. memory pressure). |
| <span style="white-space: nowrap;">node_netstat_TcpExt_TCPTimeouts</span> | <span style="white-space: nowrap;">TCP State</span> | Retransmission timeouts (RTO) fired. Counts each timeout event, not closed connections; sustained growth signals heavy loss or unreachable peers. |
| <span style="white-space: nowrap;">node_sockstat_TCP_alloc</span> | <span style="white-space: nowrap;">Socket Memory</span> | Number of allocated TCP sockets (in any state). |
| <span style="white-space: nowrap;">node_sockstat_TCP_tw</span> | <span style="white-space: nowrap;">Socket Exhaustion</span> | Connections in `TIME_WAIT` state waiting for old packets to expire. Spikes often indicate many short-lived connections, such as missing HTTP keep-alive. |
| <span style="white-space: nowrap;">node_sockstat_TCP_orphan</span> | <span style="white-space: nowrap;">Orphaned Sockets</span> | Sockets the application has already closed but the kernel is still finishing (e.g. `FIN_WAIT`, `LAST_ACK`). Growth usually means peers aren't completing the close, not an application leak. Leaked handles show up as `CLOSE_WAIT` and in rising `node_filefd_allocated` instead. |

### PromQL Queries

* **TCP Retransmission Percentage (% of total outbound segments):**

  ```
  (rate(node_netstat_Tcp_RetransSegs[$__rate_interval]) / rate(node_netstat_Tcp_OutSegs[$__rate_interval])) * 100
  ```

* **Socket Listen Backlog Drops:**

  ```
  rate(node_netstat_TcpExt_ListenDrops[$__rate_interval])
  ```

  Don't add `ListenOverflows` to this: `ListenDrops` already includes overflows, so summing them double-counts. Graph `ListenOverflows` as a separate series if you want to see how many drops came from a full accept queue.

* **Sockets in TIME_WAIT State:**

  ```
  node_sockstat_TCP_tw
  ```

## 4. Connection Tracking (Netfilter / Conntrack)

Tracks the state of kernel connection tracking used by iptables, firewalls, and NAT. These metrics only exist on hosts where the `nf_conntrack` kernel module is loaded.

| Metric Name | Focus Area | Description / Cause of Spikes |
| ----- | ----- | ----- |
| <span style="white-space: nowrap;">node_nf_conntrack_entries</span> | <span style="white-space: nowrap;">Kernel State</span> | Number of currently allocated netfilter connection tracking entries. |
| <span style="white-space: nowrap;">node_nf_conntrack_entries_limit</span> | <span style="white-space: nowrap;">Limits</span> | Maximum size of the netfilter connection tracking table (`net.netfilter.nf_conntrack_max`). |

### PromQL Queries

* **Conntrack Table Saturation Percentage:**

  ```
  (node_nf_conntrack_entries / node_nf_conntrack_entries_limit) * 100
  ```

## 5. CPU Utilization, Load & Process State

Monitors processor state breakdowns, operating system queue lengths, and active process states.

| Metric Name | Focus Area | Description / Cause of Spikes |
| ----- | ----- | ----- |
| <span style="white-space: nowrap;">node_cpu_seconds_total</span> | <span style="white-space: nowrap;">CPU Breakdown</span> | Total CPU time spent per mode (`user`, `system`, `iowait`, `idle`, `steal`). |
| <span style="white-space: nowrap;">node_load1</span> | <span style="white-space: nowrap;">System Load</span> | 1-minute load average (active CPU + uninterruptible I/O threads). |
| <span style="white-space: nowrap;">node_load5</span> | <span style="white-space: nowrap;">System Load</span> | 5-minute load average. |
| <span style="white-space: nowrap;">node_load15</span> | <span style="white-space: nowrap;">System Load</span> | 15-minute load average. |
| <span style="white-space: nowrap;">node_procs_running</span> | <span style="white-space: nowrap;">Scheduler</span> | Number of processes currently executing or ready to run on CPU. |
| <span style="white-space: nowrap;">node_procs_blocked</span> | <span style="white-space: nowrap;">I/O Bottlenecks</span> | Number of processes in uninterruptible sleep (`D` state), almost always waiting on disk or network filesystem (NFS) I/O. Ordinary socket waits don't count here. |

### PromQL Queries

* **Overall CPU Usage (% non-idle):**

  ```
  100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[$__rate_interval])) * 100)
  ```

* **CPU Time Spent in I/O Wait (`iowait`):**

  ```
  avg by (instance) (rate(node_cpu_seconds_total{mode="iowait"}[$__rate_interval])) * 100
  ```

* **Load Average vs. CPU Core Count:**

  ```
  node_load1
  node_load5
  node_load15
  count by (instance) (node_cpu_seconds_total{mode="idle"})
  ```

  Graph the three load averages with the core count as a dashed reference line. Load above the core count means more work is queued than there are cores to run it.

## 6. System Memory & Swap

Provides visibility into OS RAM usage, cache, and swap pressure.

| Metric Name | Focus Area | Description / Cause of Spikes |
| ----- | ----- | ----- |
| <span style="white-space: nowrap;">node_memory_MemTotal_bytes</span> | <span style="white-space: nowrap;">Memory Capacity</span> | Total usable physical RAM capacity. |
| <span style="white-space: nowrap;">node_memory_MemFree_bytes</span> | <span style="white-space: nowrap;">Unallocated RAM</span> | Memory completely unallocated by the OS. |
| <span style="white-space: nowrap;">node_memory_MemAvailable_bytes</span> | <span style="white-space: nowrap;">Available Memory</span> | Estimated RAM available for starting new applications without swapping. |
| <span style="white-space: nowrap;">node_memory_Cached_bytes</span> | <span style="white-space: nowrap;">Page Cache</span> | Memory used for caching disk pages. |
| <span style="white-space: nowrap;">node_memory_Buffers_bytes</span> | <span style="white-space: nowrap;">OS Buffers</span> | Temporary storage for raw disk blocks. |
| <span style="white-space: nowrap;">node_memory_SwapTotal_bytes</span> | <span style="white-space: nowrap;">Swap Capacity</span> | Total configured swap space on disk. |
| <span style="white-space: nowrap;">node_memory_SwapFree_bytes</span> | <span style="white-space: nowrap;">Available Swap</span> | Unused swap space remaining on disk. |

### PromQL Queries

* **Memory Usage Percentage:**

  ```
  (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100
  ```

* **Swap Usage Percentage:**

  ```
  (1 - (node_memory_SwapFree_bytes / node_memory_SwapTotal_bytes)) * 100
  and node_memory_SwapTotal_bytes > 0
  ```

  The `and` clause skips hosts with no swap configured, which would otherwise return `NaN` (0 / 0).

## 7. Storage Capacity, Disk I/O & Saturation

Tracks disk utilization, IOPS, throughput, and space availability.

| Metric Name | Focus Area | Description / Cause of Spikes |
| ----- | ----- | ----- |
| <span style="white-space: nowrap;">node_filesystem_size_bytes</span> | <span style="white-space: nowrap;">Capacity</span> | Total capacity of filesystem mounts in bytes. |
| <span style="white-space: nowrap;">node_filesystem_free_bytes</span> | <span style="white-space: nowrap;">Free Space</span> | Unused space in bytes, **including** blocks reserved for root (typically 5% on ext4). |
| <span style="white-space: nowrap;">node_filesystem_avail_bytes</span> | <span style="white-space: nowrap;">Availability</span> | Space actually available to non-root processes. Applications hit "disk full" when this reaches zero. |
| <span style="white-space: nowrap;">node_disk_read_bytes_total</span> | <span style="white-space: nowrap;">Throughput</span> | Total bytes read from block storage devices. |
| <span style="white-space: nowrap;">node_disk_written_bytes_total</span> | <span style="white-space: nowrap;">Throughput</span> | Total bytes written to block storage devices. |
| <span style="white-space: nowrap;">node_disk_reads_completed_total</span> | <span style="white-space: nowrap;">IOPS</span> | Total read operations completed. |
| <span style="white-space: nowrap;">node_disk_writes_completed_total</span> | <span style="white-space: nowrap;">IOPS</span> | Total write operations completed. |
| <span style="white-space: nowrap;">node_disk_io_time_seconds_total</span> | <span style="white-space: nowrap;">Disk Saturation</span> | Total seconds spent doing I/O operations. Used to compute disk % busy. |
| <span style="white-space: nowrap;">node_md_disks</span> | <span style="white-space: nowrap;">Hardware / RAID</span> | Number of disks in Linux Software RAID (`mdadm`) arrays, split by the `state` label (`active`, `failed`, `spare`). |

### PromQL Queries

* **Filesystem Usage Percentage:**

  ```
  (1 - (node_filesystem_avail_bytes{fstype!="", fstype!~"tmpfs|devtmpfs|overlay|squashfs|ramfs|nsfs|autofs|fuse.*"} / node_filesystem_size_bytes{fstype!="", fstype!~"tmpfs|devtmpfs|overlay|squashfs|ramfs|nsfs|autofs|fuse.*"})) * 100
  ```

  Uses `avail_bytes` so 100% means applications can no longer write. Using `free_bytes` understates usage by the root-reserved space. The `fstype` filter excludes virtual and in-memory filesystems.

* **Disk Read / Write Throughput (bytes/sec per device):**

  ```
  rate(node_disk_read_bytes_total{device!~"loop.*|ram.*|sr.*"}[$__rate_interval])
  rate(node_disk_written_bytes_total{device!~"loop.*|ram.*|sr.*"}[$__rate_interval])
  ```

  Set the Grafana panel unit to `bytes/sec (SI)` to display KB/s, MB/s and so on automatically. For a fixed MiB/s number, divide by `1024 / 1024`.

* **Disk Utilization (% Time Spent Doing I/O):**

  ```
  rate(node_disk_io_time_seconds_total{device!~"loop.*|ram.*|sr.*"}[$__rate_interval]) * 100
  ```

  Near 100% means saturated on a single spinning disk. SSDs, NVMe drives and RAID arrays serve many requests in parallel, so they can show close to 100% while still having headroom.

* **Failed RAID Member Disks:**

  ```
  node_md_disks{state="failed"} > 0
  ```

## 8. File Handles & System Time Sync

Monitors OS-wide file descriptor allocations and host system time drift.

| Metric Name | Focus Area | Description / Cause of Spikes |
| ----- | ----- | ----- |
| <span style="white-space: nowrap;">node_filefd_allocated</span> | <span style="white-space: nowrap;">Open Handles</span> | Currently open file handles system-wide (includes sockets and disk files). |
| <span style="white-space: nowrap;">node_filefd_maximum</span> | <span style="white-space: nowrap;">System Limit</span> | Maximum allowed open file handles (`fs.file-max`). |
| <span style="white-space: nowrap;">node_time_seconds</span> | <span style="white-space: nowrap;">System Clock</span> | Current system Unix timestamp. |
| <span style="white-space: nowrap;">node_timex_offset_seconds</span> | <span style="white-space: nowrap;">Time Drift</span> | Offset between system clock and NTP reference source. |
| <span style="white-space: nowrap;">node_uname_info</span> | <span style="white-space: nowrap;">Metadata</span> | System architecture, kernel release, and OS hostname details (always evaluates to `1`). |

### PromQL Queries

* **File Descriptor Usage Percentage:**

  ```
  (node_filefd_allocated / node_filefd_maximum) * 100
  ```

* **NTP Time Offset (Milliseconds):**

  ```
  node_timex_offset_seconds * 1000
  ```

* **Clock Skew vs. Scrape Time (Seconds):**

  ```
  node_time_seconds - timestamp(node_time_seconds)
  ```

  Compares the host's clock with the time the sample was scraped. Useful as a cross-check when NTP itself is misreporting.

## Grafana Alloy Configuration & Complete Keep Rule

To keep **only** these network, system, CPU, disk, memory, and file descriptor metrics while dropping unneeded collector metrics, use the complete `prometheus.relabel` rule below in your Alloy configuration.

The regex also keeps `up`, which Alloy generates for every scrape target. Without it you lose the ability to alert when a host stops reporting.

```alloy
prometheus.relabel "keep_core_node_metrics" {
  forward_to = [prometheus.remote_write.default.receiver]

  rule {
    action        = "keep"
    source_labels = ["__name__"]
    regex         = "up|node_nf_conntrack_entries|node_nf_conntrack_entries_limit|node_load1|node_load5|node_load15|node_filesystem_size_bytes|node_filesystem_free_bytes|node_filesystem_avail_bytes|node_memory_SwapFree_bytes|node_memory_SwapTotal_bytes|node_procs_running|node_procs_blocked|node_network_receive_bytes_total|node_network_transmit_bytes_total|node_md_disks|node_uname_info|node_memory_MemTotal_bytes|node_memory_MemFree_bytes|node_memory_MemAvailable_bytes|node_memory_Cached_bytes|node_memory_Buffers_bytes|node_network_receive_errs_total|node_network_transmit_errs_total|node_network_receive_drop_total|node_network_transmit_drop_total|node_netstat_Tcp_InErrs|node_netstat_Udp_InErrors|node_netstat_Udp_NoPorts|node_netstat_Udp_RcvbufErrors|node_netstat_Tcp_RetransSegs|node_netstat_Tcp_OutSegs|node_netstat_TcpExt_TCPSynRetrans|node_netstat_TcpExt_ListenDrops|node_netstat_TcpExt_ListenOverflows|node_netstat_TcpExt_TCPTimeouts|node_network_receive_packets_total|node_network_transmit_packets_total|node_sockstat_TCP_alloc|node_sockstat_TCP_tw|node_sockstat_TCP_orphan|node_disk_read_bytes_total|node_disk_written_bytes_total|node_disk_reads_completed_total|node_disk_writes_completed_total|node_disk_io_time_seconds_total|node_filefd_allocated|node_filefd_maximum|node_cpu_seconds_total|node_time_seconds|node_timex_offset_seconds"
  }
}
```