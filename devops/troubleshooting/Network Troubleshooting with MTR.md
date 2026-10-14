#### Network Troubleshooting with MTR

MTR combines traceroute and ping: it sends probes with increasing TTL values so each router along the path returns an ICMP "Time Exceeded" message, then repeats continuously to give per-hop loss and latency. The three modes differ only in **what kind of probe packet is sent**, which changes how routers and firewalls treat it.

#### Installing

| Platform | Command | Notes |
|---|---|---|
| Debian / Ubuntu | `sudo apt install mtr-tiny` | `mtr` for the version with a graphical interface |
| RHEL / Fedora | `sudo dnf install mtr` | |
| macOS | `brew install mtr` | Usually needs `sudo` to run |
| Windows | WinMTR | ICMP only; no UDP or TCP mode |

All three modes need raw socket access. Most Linux packages grant this to MTR's helper binary, so it runs without `sudo`. On macOS, expect to use `sudo` for every mode.

#### The three modes

| | ICMP (default) | UDP (`-u`) | TCP (`-T`) |
|---|---|---|---|
| Probe packet | ICMP Echo Request | UDP datagram to a high port | TCP SYN to a port (default 80) |
| Final hop replies with | ICMP Echo Reply | ICMP Port Unreachable | SYN-ACK (open) or RST (closed) |
| Command | `mtr host` | `mtr -u host` | `mtr -T -P 443 host` |
| Best for | General path checks | Seeing ECMP/load-balanced paths, mimicking UDP apps | Testing the path real application traffic takes through firewalls |

#### ICMP

- Simple and widely supported, so it's the usual starting point.
- Often rate-limited or deprioritized by routers, and sometimes blocked by firewalls. This can show loss or `???` that real traffic never experiences.
- Has no ports, so load balancers usually hash it onto a single path. It may not be the path your application traffic uses.

#### UDP

- Same style as classic Unix `traceroute`.
- Because it has ports, ECMP routers hash it like real traffic, and varying ports can reveal multiple parallel paths.
- Useful when troubleshooting UDP-based services (DNS, VoIP, QUIC, gaming).
- Firewalls frequently drop UDP to arbitrary high ports, so the last hops or destination may not respond.

#### TCP

- Sends SYNs to a port you choose (`-P 443`, `-P 22`, etc.), so it looks like a real connection attempt.
- Most likely to get through firewalls and to follow the same policy routing, QoS, and load-balancing as your actual application.
- Best choice for "the website is slow/unreachable but ping looks fine" and for targets that block ICMP.
- Caveats: some firewalls/IDS treat repeated SYNs as a scan, and a stateful device in the middle may answer on behalf of the destination, making the path look shorter than it is.

#### Useful flags

| Flag | Purpose |
|---|---|
| `-r` | Report mode: run the set number of cycles, then print a summary |
| `-c N` | Number of cycles to run |
| `-w` | Wide report; don't truncate hostnames |
| `-n` | Skip DNS lookups; faster and avoids misleading names |
| `-b` | Show both hostnames and IP addresses |
| `-z` | Show the AS number for each hop |
| `-e` | Show MPLS labels |
| `-i SECONDS` | Interval between probes |
| `-s BYTES` | Packet size; useful for MTU problems |
| `-4` / `-6` | Force IPv4 or IPv6 |
| `--json` / `--csv` | Output for scripts |

#### The columns

| Column | Meaning |
|---|---|
| Loss% | Percentage of probes with no reply from that hop |
| Snt | Probes sent |
| Last | Latency of the most recent probe (ms) |
| Avg | Average latency |
| Best | Lowest latency seen |
| Wrst | Highest latency seen |
| StDev | Standard deviation; a high value means jitter |

Jitter matters for voice and video even when the average looks fine.

#### Reading the results (applies to all modes)

- **Loss at a middle hop that doesn't continue to the final hop** is almost always ICMP rate limiting on that router, not real loss. Routers generate "Time Exceeded" replies with low priority.
- **Loss that starts at a hop and persists through to the destination** is real.
- **Latency follows the same rule.** A spike at one hop that doesn't carry through to later hops is just that router being slow to reply. A jump that persists is real, though it may simply be distance, such as an ocean crossing.
- Intermediate hops always reply with ICMP regardless of mode, so if a network blocks outbound ICMP Time Exceeded you'll see `???` in every mode.
- In UDP and TCP modes a single hop may show several router IPs. This is normal on load-balanced paths and not a fault.
- Paths are often asymmetric; run MTR from both ends if you can.

#### Practical approach

1. Start with ICMP: `mtr -rwzbc 100 host` (report mode, wide, show ASN, show IPs and names, 100 cycles).
2. If the results look bad but the application works, or ICMP is blocked, rerun with TCP on the application's port: `mtr -T -P 443 -rwc 100 host`.
3. Use UDP when the affected service is UDP or you suspect one leg of a load-balanced path is bad.

#### Sample size and timing

- Treat 100 cycles as a minimum. Intermittent problems need longer runs.
- Capture while the problem is happening. A clean run afterwards proves little.
- Keep a baseline from when things are healthy so you have something to compare against.

#### What to send a provider

- Report-mode output (`-rwzbc 100`) from both directions.
- Source and destination IP addresses.
- Timestamps with time zone.
- The mode and port used, if not ICMP.
- A healthy baseline, if you have one.

#### Companion tools

MTR measures loss and latency along a path. It does not measure bandwidth.

| Tool | Use it for |
|---|---|
| `iperf3` | Throughput between two hosts; the usual default |
| `iperf` (iperf2) | Multicast, or many clients testing against one server at once |
| `tcptraceroute` | A one-off TCP path check where MTR isn't installed |
| `paris-traceroute` / `dublin-traceroute` | Mapping every branch of a load-balanced path |

iperf3 and iperf2 are not compatible; both ends must run the same one.