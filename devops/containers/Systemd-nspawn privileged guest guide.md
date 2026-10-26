# Privileged systemd-nspawn Guest — Build & Deploy Guide

A "chroot on steroids": capture a running bare-metal Debian machine as a rootfs and run it under `systemd-nspawn` on another host, with enough privilege to change host kernel state (sysctls, bridges, nftables/iptables) while the host keeps its own init, kernel, boot and networking.

---

## 1. Design summary

| Decision | Choice |
|---|---|
| Host role | Runs **only** `systemd-nspawn` and the guest. Nothing else is served from the host. |
| Guest count | **One guest per host.** |
| Host PID 1 | Stays the host's systemd. The guest never becomes PID 1. |
| Kernel / bootloader | Host's. The guest brings neither. |
| Guest filesystem | Its own self-contained rootfs. No overlay on the host's `/`, and no bind mounts of host paths. |
| Network | The guest **shares the host network namespace**. Its bridges and firewall rules are real host objects. |
| Host networking | **Owned by the host.** The guest only creates its own bridges and its own named nft tables. |
| Capabilities | `all`, minus `CAP_SYS_MODULE`. |
| Seccomp | Off (`SYSTEMD_SECCOMP=0`). See section 5 for why. |
| Teardown on stop | **None.** Bridges, tables and sysctls stay in the host kernel until reboot. Guest setup is idempotent. |
| Kernel versions | **Will drift** between source, guest userspace and host. The host owns all module loading. See section 8. |
| `/proc/sys`, `/sys` | Writable (`SYSTEMD_NSPAWN_API_VFS_WRITABLE=1`), so the guest sets sysctls. Alternative: host-managed sysctls with read-only `/proc/sys` and `/sys` (section 7.1). |
| Devices | `DevicePolicy=auto`. With `CAP_MKNOD` the guest can create and open any node it needs (section 9). |
| PID / mount / cgroup namespaces | Kept. The guest sees only its own processes and its own delegated cgroup subtree. |

**What the guest can do to the host:**
- set global sysctls (`kernel.*`, `vm.*`, `fs.*`) and `net.*` sysctls;
- create bridges and other network devices;
- load nftables and iptables rules;
- use RT scheduling and raise rlimits;
- access devices.

**What it can't do:**
- see host files or processes;
- reboot or power off the host (`reboot` inside the guest only stops the guest);
- load kernel modules.

---

## 2. Host prerequisites (target machine)

1. **Install nspawn.** It isn't installed by default on Debian.
   ```bash
   apt install systemd-container
   ```

2. **Make the host network manager ignore guest-created interfaces.** Use a fixed name prefix, e.g. `gbr*` for bridges and `gv*` for other links.
   - systemd-networkd: `/etc/systemd/network/10-guest-unmanaged.network`
     ```ini
     [Match]
     Name=gbr* gv*

     [Link]
     Unmanaged=yes
     ```
   - NetworkManager: `/etc/NetworkManager/conf.d/guest-unmanaged.conf`
     ```ini
     [keyfile]
     unmanaged-devices=interface-name:gbr*;interface-name:gv*
     ```
   - ifupdown: nothing needed. It only touches interfaces it's configured for.

3. **Keep the host's firewall out of the way.** The host runs nothing but nspawn, so it doesn't need a ruleset of its own. Disable the host's stock `nftables.service` (`systemctl disable --now nftables.service`). Its `/etc/nftables.conf` starts with `flush ruleset`, which would wipe the guest's tables on any reload. If you do want host-side rules (e.g. to protect management SSH), put them in their own named table, never `flush ruleset`.

   ⚠️ **The guest's rules are effectively the host's firewall.** The network namespace is shared, so an `input` chain with `policy drop` in the guest also blocks traffic to the host's own sshd and management services. Either allow management traffic explicitly in the guest's input chain, or don't give the guest an `input` hook at all.

4. **Load modules the kernel won't autoload.** If the guest needs `br_netfilter` (for iptables or `inet` rules to see bridged traffic), the host must load it, because the guest has no `CAP_SYS_MODULE`.
   ```bash
   echo br_netfilter > /etc/modules-load.d/guest.conf
   ```
   Bridge creation itself is fine: the kernel autoloads `bridge` using the host's modprobe.

5. **iptables backend.** The host doesn't run iptables, so there's no host backend to match. The guest should use **`iptables-nft`** (Debian's default). Check with `update-alternatives --display iptables` inside the guest, and switch with `update-alternatives --set iptables /usr/sbin/iptables-nft` (likewise `ip6tables`) if the source machine used legacy. `iptables-legacy` tends to call `modprobe` for `ip_tables`, which fails in the guest. The nft backend relies on kernel autoloading, which works.

---

## 3. Capturing the source bare-metal machine

### 3.1 Consistency
If the root is on LVM, btrfs or ZFS, snapshot it and archive the snapshot. Otherwise stop write-heavy services (databases etc.) during the capture. On a live system, tar may warn "file changed as we read it" and exit 1. That's expected for logs and similar files.

### 3.2 Separate filesystems
`--one-file-system` stops at mount points. List the real filesystems with:
```bash
findmnt -t ext4,xfs,btrfs
```
Add each separate one (`./var`, `./home`, …) as an extra tar argument after `.`.

### 3.3 Stream with tar + nc (trusted network only)

**Receiver first** (target host):
```bash
mkdir -p /var/lib/machines/guest

# netcat-openbsd (Debian default); netcat-traditional uses: nc -l -p 9000
nc -l 9000 \
  | tee >(sha256sum >&2) \
  | zstd -d \
  | tar --extract \
        --directory=/var/lib/machines/guest \
        --numeric-owner \
        --xattrs --xattrs-include='*' \
        --acls \
        --same-permissions
```

**Then the sender** (source machine):
```bash
tar --create --directory=/ \
    --one-file-system \
    --numeric-owner \
    --xattrs --xattrs-include='*' \
    --acls \
    --sparse \
    --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' \
    --exclude='./run/*'  --exclude='./tmp/*' --exclude='./mnt/*' \
    --exclude='./media/*' --exclude='./lost+found' \
    --exclude='./var/lib/machines/*' --exclude='./swapfile' \
    --exclude='./var/cache/apt/archives/*.deb' \
    . \
  | zstd -T0 -3 \
  | tee >(sha256sum >&2) \
  | nc -N receiver.example 9000
```

**Notes**
- `-N` (openbsd nc) closes the connection at EOF. Without it, both ends hang. netcat-traditional uses `-q 0` instead.
- The two `sha256sum` outputs must match. Also check both sides' exit status.
- On 10 GbE or faster, try without `zstd` (on both ends). Compression can become the bottleneck.
- Add `pv` in the pipe for progress.
- The receiver's firewall must allow the port. Remove that rule afterwards.
- **nc is plaintext and unauthenticated.** Anyone who can reach the port can read the stream or push data into it. Off an isolated network, use ssh instead:
  ```bash
  tar --create ... . | zstd -T0 -3 | ssh target 'zstd -d | tar --extract ...'
  ```

### 3.4 Why the flags matter

| Flag | Reason |
|---|---|
| `--xattrs --xattrs-include='*'` | Keeps file capabilities (`security.capability`, e.g. `ping`, `mtr-packet`). On extract, GNU tar won't restore `security.*` xattrs without `--xattrs-include`. |
| `--acls` | Stock Debian barely uses ACLs (journald's are reapplied by tmpfiles). They matter only if someone set ACLs by hand. Check with `getfacl -R -s -p /etc /var /srv /opt`. |
| `--numeric-owner` | Stores UIDs and GIDs as numbers, so names aren't remapped against the receiving host. |
| `--sparse` | Keeps sparse files (VM disks, databases) from ballooning. |
| `dir/*` excludes | Keep the empty mount-point directories. |
| `--directory=/ .` | Relative paths, so the archive extracts into any directory. |

To see what file capabilities exist on the source: `getcap -r / 2>/dev/null`.

### 3.5 What happens if xattrs or ACLs are missed

**They're silently dropped, with no warning.**
- **GNU tar (Debian's `tar`):**
  - creating without `--xattrs`/`--acls` doesn't store them;
  - extracting without the flags ignores what's in the archive;
  - extracting without `--xattrs-include='*'` skips `security.*` xattrs, including file capabilities.
- **What's still preserved:** ordinary mode bits (including setuid and setgid), owner, group and timestamps. These are in the basic tar header.
- **bsdtar (libarchive) behaves differently:** it stores and restores xattrs and ACLs by default when run as root. The same command line can behave differently depending on which tar is installed.

**Side effects of losing them:**

| Lost | Effect |
|---|---|
| File capabilities (`security.capability`) | Binaries using `setcap` instead of setuid (`ping`, `mtr-packet`, …) lose their privileges. Non-root users get "Operation not permitted"; root is unaffected. |
| Extended ACLs | **Group permissions can become more permissive.** With an extended ACL, the "group" bits in the mode hold the ACL *mask*, not the owning group's permissions. Drop the ACL and those bits become the real group permissions. E.g. `group::r-x` + `user:bob:rwx` shows group `rwx` in `ls -l`, and after the ACL is lost the owning group really gets `rwx`. |
| Default ACLs on directories | New files get permissions from the umask instead of inheriting. |
| Other xattrs (journald metadata, user-defined) | No functional effect in this design. |

**Recovering after the fact.** Dump them on the source and reapply on the target:
```bash
# source
getcap -r / 2>/dev/null > caps.txt
getfacl -R -s -p / 2>/dev/null > acls.txt   # only files with real ACLs

# target: run inside the guest so the paths match
systemd-nspawn -D $G setfacl --restore=/path/to/acls.txt
```
Re-run `setcap` for each line of `caps.txt` (example below).

**Restoring a single capability, e.g. `ping`:**
```bash
# inside the guest
setcap cap_net_raw+ep /usr/bin/ping

# or from the host, without entering the guest
setcap cap_net_raw+ep /var/lib/machines/guest/usr/bin/ping

# verify — should print: /usr/bin/ping cap_net_raw=ep
getcap /usr/bin/ping
```
Alternatively, `apt reinstall iputils-ping` inside the guest. Its postinst script reapplies the capability.

**Alternative to streaming:** write to a file (`--file=/mnt/backup/guest.tar.zst --zstd`, on another filesystem). Then use `machinectl import-tar guest.tar.zst guest` on the target, which extracts and registers it in one step.

---

## 4. Turning the rootfs into a guest

All of this can be done from the host while the guest is stopped.

```bash
G=/var/lib/machines/guest

# Identity
rm -f $G/etc/machine-id
systemd-machine-id-setup --root=$G
echo guest > $G/etc/hostname

# The guest must not try to mount the host's disks
: > $G/etc/fstab
: > $G/etc/crypttab

# Mask everything that would compete with the host or expects real hardware
systemctl --root=$G mask \
  systemd-udevd.service systemd-udevd-control.socket systemd-udevd-kernel.socket \
  systemd-udev-trigger.service \
  systemd-timesyncd.service chrony.service ntpsec.service ntp.service \
  networking.service NetworkManager.service \
  nftables.service \
  apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service \
  smartd.service mdmonitor.service lvm2-monitor.service multipathd.service \
  irqbalance.service thermald.service \
  systemd-modules-load.service
```

**Why each group:**

| Masked | Reason |
|---|---|
| udevd | `/sys` is writable, so its start condition passes. Because the network namespace is shared, it would also receive and process the host's uevents. |
| timesyncd / chrony / ntp | With `CAP_SYS_TIME`, the guest would set the host clock. |
| networking / NetworkManager | The host owns networking. |
| `systemd-networkd` | Mask it too, **unless** the guest uses it for its bridges (see 6.1). |
| `nftables.service` | The stock config does `flush ruleset`, which wipes the *entire* host ruleset. Masking it means the guest's rules are loaded by its own unit (section 6.4) into a named table. **Masking is optional for this deployment:** the host has no firewall, so you can instead leave it enabled and let the guest own the whole ruleset. See section 6.2, Option A. |
| apt timers | No surprise upgrades of the guest. |
| smartd, mdadm, lvm, multipath, irqbalance, thermald | Hardware-facing. These fail or contend with the host. |
| `systemd-modules-load` | It already skips itself without `CAP_SYS_MODULE`; masking makes the intent explicit. |

Masking a unit that doesn't exist in the image is harmless.

**SSH:** the guest shares the host's network namespace, so its sshd would collide with the host's on port 22. Either `systemctl --root=$G mask ssh.service ssh.socket`, or move it to another port and regenerate its host keys. `machinectl shell guest` works without sshd.

**Purge kernel and boot packages:** remove `linux-image-*`, `grub*`, `initramfs-tools` and `firmware-*`. The guest's kernel modules will never match the host's kernel and can't be loaded anyway (section 8). Leaving them in only invites tools to look in the wrong `/lib/modules/` tree.
```bash
systemd-nspawn -D $G apt purge 'linux-image-*' 'grub*' initramfs-tools 'firmware-*'
```

**Optional quieting of modprobe calls:** tools that call `modprobe` directly log "Operation not permitted". To silence them:
```bash
systemd-nspawn -D $G dpkg-divert --local --rename --add /sbin/modprobe
ln -s /bin/true $G/sbin/modprobe
```
Also empty `$G/etc/modules` and `$G/etc/modules-load.d/`.

---

## 5. The service unit

`/etc/systemd/system/guest.service`

```ini
[Unit]
Description=Privileged guest ("chroot on steroids")
Documentation=man:systemd-nspawn(1)
After=network.target
PartOf=machines.target
Before=machines.target

[Service]
# /proc/sys and /sys writable inside the guest (sysctls hit the host kernel)
Environment=SYSTEMD_NSPAWN_API_VFS_WRITABLE=1
# No seccomp filter (see "Seccomp choice" below)
Environment=SYSTEMD_SECCOMP=0

ExecStart=/usr/bin/systemd-nspawn \
    --quiet \
    --keep-unit \
    --boot \
    --notify-ready=yes \
    --machine=guest \
    --directory=/var/lib/machines/guest \
    --private-users=no \
    --capability=all \
    --drop-capability=CAP_SYS_MODULE \
    --resolv-conf=copy-host \
    --link-journal=no
# No --network-* / --private-network flags: the guest shares the host netns.
# For a single-file image use --image=/var/lib/machines/guest.raw instead of --directory.

Type=notify
NotifyAccess=all
Delegate=yes
KillMode=mixed
Slice=machine.slice
Restart=on-failure
RestartForceExitStatus=133
SuccessExitStatus=133

# cgroup task cap for the whole guest (not an rlimit). Remove to use the host default.
TasksMax=infinity
# No device restrictions; with CAP_MKNOD the guest can create and open any node
DevicePolicy=auto

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now guest.service
machinectl shell guest
```

### Why a standalone unit rather than `systemd-nspawn@.service`
The stock template's `ExecStart` hard-codes `--network-veth` and `-U` (private network and user namespacing), which are the opposite of what this design needs. A standalone unit also makes every flag visible.

### Seccomp choice: `SYSTEMD_SECCOMP=0` (decided)

| Option | Effect |
|---|---|
| `Environment=SYSTEMD_SECCOMP=0` **(chosen)** | No filter at all. |
| `--system-call-filter=@privileged` (nspawn flag) | Adds the privileged group to nspawn's allowlist. Syscalls outside both lists (`@obsolete`, `@cpu-emulation`, syscalls newer than this systemd) stay blocked. |

**Why off is the better choice here:**
- **The filter adds almost no protection.** The guest already has every capability except `CAP_SYS_MODULE` and no user namespace. Nearly every dangerous syscall is capability-gated, so the filter would allow it anyway. Module loading is blocked by the dropped capability, not by seccomp.
- **There's nothing on the host left to protect.** The host runs nothing except this one guest.
- **The filter's only real effect is a failure mode.** It blocks obscure or newer syscalls with `EPERM`. That gets more likely as guest userspace and host kernel drift apart, and it's hard to diagnose.

⚠️ Do **not** put `SystemCallFilter=@privileged` in the unit's `[Service]` section. That's systemd's own sandboxing directive. It applies to nspawn and everything it starts, and *restricts* them to that list.

### Capabilities
`--capability=` *adds* to nspawn's default set; it doesn't replace it. The default set already includes `CAP_SYS_ADMIN`, `CAP_SYS_RESOURCE` and `CAP_SYS_NICE`. Here `all` adds the rest, including `CAP_NET_ADMIN`, `CAP_SYS_TIME`, `CAP_SYS_RAWIO` and `CAP_MKNOD`, and `--drop-capability` removes `CAP_SYS_MODULE`.

---

## 6. Guest networking

### 6.1 Bridges
- Create them with a distinct prefix (`gbr*`), using a oneshot unit (simplest) or systemd-networkd `.netdev` files.
- **If the guest runs systemd-networkd**, set this in the guest's `/etc/systemd/networkd.conf`. By default networkd removes routes and rules it didn't create, which would include the host's.
  ```ini
  [Network]
  ManageForeignRoutes=no
  ManageForeignRoutingPolicyRules=no
  ManageForeignNextHops=no
  ```
  Its `.network` files must match only guest-owned interface names.

### 6.2 nftables

No unit changes are needed for the guest to maintain its own rules. `CAP_NET_ADMIN` plus the shared network namespace is enough. nft talks to the kernel over netlink, so read-only `/proc/sys`/`/sys` (section 7.1) doesn't affect it. Missing nft expression modules are autoloaded by the host's modprobe.

The choice is *how* the guest loads its rules:

| | Option A: guest owns the whole ruleset | Option B: guest owns a named table |
|---|---|---|
| Guest `nftables.service` | **Enabled** (removed from the section 4 mask list) | **Masked** (section 4) |
| Rules file | Guest's `/etc/nftables.conf`, stock `flush ruleset` at the top | Custom file loaded by `guest-net.service` (section 6.4) |
| Reload behavior | Replaces everything, so no stale rules after a restart or image swap | `destroy table inet guest` then redefine; only the guest's table changes |
| Host requirement | Host `nftables.service` disabled and **no** host-side rules at all, since they'd be flushed | Host may keep its own named tables |
| Fits when | The host runs nothing but nspawn (this deployment) | Host-side rules (e.g. management) may be added later |

**Option B is what the rest of this guide shows.** Option A is simpler for the current decisions. To switch:
```bash
systemctl --root=$G unmask nftables.service
systemctl --root=$G enable nftables.service
```
Then drop the `nft -f` line from `guest-net.service`.

**Under either option:**
- **Forwarding** needs `net.ipv4.ip_forward=1` (and the IPv6 equivalent). Conntrack tunables like `net.netfilter.nf_conntrack_max` likewise. Set them in the guest's `sysctl.d`, or on the host if sysctls are host-managed (section 7.1).
- **iptables-nft tools in the guest** (Docker, fail2ban) put their tables into the same ruleset. Under Option A, a `flush ruleset` reload removes them until those tools re-add their rules, the same as on bare metal.

**Option B details:**
- The guest manages **only its own named tables**, e.g. `table inet guest`, and never uses `flush ruleset`.
- Refresh its tables idempotently. On trixie (nft ≥ 1.0.8):
  ```
  destroy table inet guest
  table inet guest { ... }
  ```
  On bookworm, use `table inet guest` then `delete table inet guest` at the top of the file.
- Multiple base chains on the same hook **all run, in priority order**. An `accept` in one table doesn't stop the others; a `drop` anywhere is final. With the host's firewall disabled (section 2), the guest's tables are the only ones, so this matters only if host-side management rules are added later.
- Traffic is almost entirely forwarded or bridged through the guest, so most guest rules belong on the `forward` hook (or the `bridge` family). See the warning in section 2 about `input` chains.
- The nft `bridge` family needs no extra module. Seeing bridged traffic in `ip`/`inet`/iptables rules needs `br_netfilter`, loaded by the host.

### 6.3 iptables
- It must use the same backend as the host. `iptables-nft` is the default on Debian. Never mix `iptables-legacy` and `iptables-nft` between host and guest.
- Tools in the guest that write iptables rules (Docker, libvirt, fail2ban, …) will write into the host ruleset.

### 6.4 Example guest network unit
`/etc/systemd/system/guest-net.service` (inside the guest)
```ini
[Unit]
Description=Guest bridges and firewall tables
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'ip link show gbr0 >/dev/null 2>&1 || ip link add gbr0 type bridge'
ExecStart=/sbin/ip link set gbr0 up
ExecStart=/usr/sbin/nft -f /etc/guest/nftables.nft
# No ExecStop teardown: objects persist in the host kernel until reboot,
# and every ExecStart line above is safe to re-run.

[Install]
WantedBy=multi-user.target
```

### 6.5 Kernel state outlives the guest (by design)
There's no teardown. Bridges, nft tables and sysctls stay in the host kernel after `systemctl stop guest` and are cleared only by a host reboot. Consequences:
- **Guest setup must be idempotent.** Create a bridge only if it's missing, and use `destroy table` before redefining a table.
- **A replaced or rolled-back image inherits the previous image's state.** That includes bridges it no longer defines, sysctls it no longer sets, and table contents if the table name changed. **Reboot the host after swapping images** if you need a clean slate.

---

## 7. Sysctls, resource limits and scheduling in the guest

- **Sysctls:** the guest's `systemd-sysctl` / `/etc/sysctl.d` work normally. `kernel.*`, `vm.*` and `fs.*` are global to the host. `net.*` affects the host too, because the network namespace is shared.
- **Service limits and scheduling:** the guest's systemd can apply these to its services, because the needed capabilities are present.

| Setting | Notes |
|---|---|
| `LimitCORE=infinity` | Core file location comes from the global `kernel.core_pattern`. |
| `LimitNOFILE=100000` | Must be ≤ `fs.nr_open` (~1M default). |
| `LimitNPROC=60000` | Counted per UID **across the whole host** (no user namespace). The host unit's `TasksMax` caps the guest overall. |
| `LimitSTACK=` | **Bytes**, not KiB. `250000` ≈ 244 KiB; use `250M` for ~250 MB. |
| `LimitRTPRIO=` / `LimitRTTIME=infinity` | Fine. |
| `IOSchedulingClass=realtime` | Only has an effect with an I/O scheduler that honors priorities (BFQ, partially mq-deadline). Ignored with `none` on NVMe. |
| `CPUSchedulingPolicy=rr` + `Priority=89` | Works. Debian kernels lack `CONFIG_RT_GROUP_SCHED`, so no cgroup RT budget is needed. |

- **RT cautions:**
  - Global RT throttling (`kernel.sched_rt_runtime_us=950000`) limits RT tasks to 95% of each CPU. The guest can change it, but the change is host-wide.
  - Priority 89 sits above most kernel threads, so a runaway RR task can starve the host.

### 7.1 Alternative: host-managed sysctls

Sysctls can live in the host's config instead of the guest's. Then the guest no longer needs a writable `/proc/sys` or `/sys`.

⚠️ **Not compatible with running Incus in the guest.** Incus writes per-interface sysctls at runtime and fails if `/proc/sys` is read-only (section 10.1).

**Changes**

1. **Unit file:** drop the writable API VFS line.
   ```diff
   - Environment=SYSTEMD_NSPAWN_API_VFS_WRITABLE=1
   ```
   `/proc/sys` and `/sys` become read-only in the guest. Nothing else in this design needs them writable: bridges and nftables use netlink, and RT scheduling and rlimits don't touch `/proc/sys`.

2. **Host:** add `/etc/sysctl.d/90-guest.conf` with the settings. The host's `systemd-sysctl` applies it at boot, before `guest.service` starts. It runs after `systemd-modules-load`, so `net.bridge.*` keys work as long as `br_netfilter` is in the host's `modules-load.d`.

3. **Guest:** nothing required. Its `systemd-sysctl.service` has `ConditionPathIsReadWrite=/proc/sys/` and skips itself. Empty the guest's `/etc/sysctl.d/` to avoid confusion.

**Benefits**
- **The guest's udevd can't start,** because its condition needs `/sys` writable. Keep the mask anyway.
- **The `kernel.modprobe` loophole (section 8) is closed.**
- **Sysctls survive image swaps.** A replaced or rolled-back image can't leave stale values behind.

**Watch out for**
- **Per-interface keys for guest-created interfaces** (e.g. `net.ipv4.conf.gbr0.forwarding`) don't exist at host boot. Either:
  - use `net.ipv4.conf.default.*` / `all.*` (`default` is copied to each new interface at creation), or
  - rely on the host's udev: systemd's udev rules re-run `systemd-sysctl` for an interface's prefix when it appears. Because the network namespace is shared, the *host's* udevd sees the guest create `gbr0` and applies per-interface keys from the host's `sysctl.d` at that moment.
- **Guest software that writes sysctls at runtime fails** with read-only errors. Docker and libvirt, for example, set `ip_forward` themselves. Set those values on the host up front.
- **Sysctl changes become host config changes** rather than guest image changes. A deployment becomes the image *plus* one host file.

Capabilities and seccomp are unchanged. Setting `SYSTEMD_NSPAWN_API_VFS_WRITABLE=0` is the same as removing the line.

**Still works with read-only `/proc/sys` and `/sys`:** RT scheduling (`CPUSchedulingPolicy=`), I/O priority (`IOSchedulingClass=`) and rlimits are syscalls, gated by capabilities rather than these filesystems. The guest's delegated cgroup subtree is still mounted writable, so `CPUWeight=`, `IOWeight=`, `CPUQuota=` etc. work. nftables and `ip link` use netlink and are unaffected.

**Moves to the host:**
- **RT throttling** (`kernel.sched_rt_runtime_us`) goes in the host's `sysctl.d`.
- **The block I/O scheduler** must be set by a host udev rule, because the guest can't write `/sys/block/*/queue/scheduler`. `IOSchedulingClass=realtime` only takes effect with BFQ (fully) or mq-deadline (partially); NVMe defaults to `none`, which ignores it.
  ```
  # /etc/udev/rules.d/60-iosched.rules  (host)
  ACTION=="add|change", KERNEL=="sd[a-z]*|nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="bfq"
  ```
  Add `bfq` to the host's `modules-load.d` if it isn't autoloaded.

#### Guest services affected by read-only `/proc/sys` and `/sys` (nothing to do)

These units notice the read-only filesystems, or the missing capability, and skip themselves cleanly, or are already masked. They show as "condition failed" or inactive, not as failed:

| Unit | Why it's harmless |
|---|---|
| `systemd-sysctl.service` | `ConditionPathIsReadWrite=/proc/sys/`, so it skips. Sysctls come from the host instead. |
| `systemd-udevd.service`, `systemd-udev-trigger.service`, `systemd-udev-settle.service` | `ConditionPathIsReadWrite=/sys`, so they skip. They're also masked (section 4). |
| `systemd-binfmt.service`, `proc-sys-fs-binfmt_misc.automount` | Need writable `/proc/sys`, so they skip. binfmt registration (e.g. qemu-user) would have to be done on the host if ever needed. |
| `systemd-modules-load.service`, `kmod-static-nodes.service` | Skip because `CAP_SYS_MODULE` is dropped (already the case without 7.1). |
| `systemd-backlight@`, `systemd-rfkill`, other udev-triggered hardware units | Only started by udev, which doesn't run in the guest. |
| `apparmor.service` | Detects that it's in a container and doesn't load policy; policy is the host's job. |
| `sys-kernel-config.mount`, `sys-kernel-debug.mount`, `sys-kernel-tracing.mount`, `sys-fs-fuse-connections.mount` | May be skipped or fail to mount. Nothing in this design uses them. |
| `nftables.service` | Unaffected (netlink). Masked or enabled per section 6.2. |
| Package maintainer scripts running `sysctl --system` / `sysctl -w` (e.g. on `procps` upgrades) | Print "Read-only file system" warnings during `apt` runs; harmless. |

**Worth knowing, but not a problem for this design:**
- **systemd-networkd** (if the guest uses it for bridges) logs warnings when it can't apply per-interface sysctl-backed settings such as `IPForward=`, `IPv6AcceptRA=` or `IPv6LinkLocalAddressGenerationMode=`. Put the equivalent keys in the host's `sysctl.d` (see "per-interface keys" above).
- **Docker and libvirt** fail to set `ip_forward` themselves. Pre-set it on the host.

---

## 8. Kernel modules and kernel version drift

The host kernel, the source machine's kernel and the guest's userspace **will** drift apart. The design accepts that by making the host the only thing that deals with modules.

- **The guest can't load modules directly,** because it has no `CAP_SYS_MODULE`. Its `/lib/modules` is purged (section 4), since it would never match the host's kernel.
- **The kernel still autoloads modules** for bridges and nft expressions, running the *host's* modprobe against the host's own `/lib/modules`. That keeps working whatever the guest's age.
- **Modules that aren't autoloaded** (e.g. `br_netfilter`) are listed in the host's `/etc/modules-load.d/guest.conf` (section 2). This list is the only host-side record of what the guest needs.

**Drift rules of thumb:**
- **Keep the host kernel at least as new as the guest's Debian release expects.** Older kernels can lack syscalls, netfilter features or sysctls that newer userspace (systemd, nft, iproute2) assumes. Failures show up as `EINVAL`/`EOPNOTSUPP` from nft or iproute2, or as warnings from the guest's systemd. Running the host on the same or a newer Debian release than the guest avoids most of this.
- **A newer host kernel under an older guest is generally fine.** The kernel's userspace ABI is backwards compatible.
- **Sysctls can appear, disappear or be renamed between kernels.** The guest's `systemd-sysctl` logs and skips unknown keys. Check `journalctl -u systemd-sysctl` in the guest after a host kernel upgrade.
- **After a host kernel upgrade, check `systemctl --failed` in the guest,** and that the bridges and nft tables were recreated. A host kernel upgrade means a host reboot, which also clears all guest-created kernel state, and the guest rebuilds it at start.
- ⚠️ The guest's writable `/proc/sys` includes `kernel.modprobe`. A guest could repoint it and break the host's autoloading. That's accepted as part of trusting the guest. Moving sysctls to the host (section 7.1) closes it, because `/proc/sys` becomes read-only.

---

## 9. Devices

The unit already lets the guest create devices; no further config is needed.

### 9.1 Network devices
Bridges, veth, tun/tap, vlan, etc. work because of `CAP_NET_ADMIN` (from `--capability=all`) plus the shared network namespace. `ip link add ...` creates real host interfaces. `/dev/net/tun` is already part of nspawn's minimal `/dev`.

### 9.2 Device nodes (`mknod`)

| Setting | Role |
|---|---|
| `--capability=all` (includes `CAP_MKNOD`) | Lets the guest *create* the node. |
| `DevicePolicy=auto` (with no `DeviceAllow=` lines) | Lets the guest *open* it. The cgroup device controller places no restriction. |

If the unit is ever tightened back to `DevicePolicy=closed`, each device needs a `DeviceAllow=` line (e.g. `DeviceAllow=block-sd rw`, `DeviceAllow=/dev/kvm rw`). Without one, nodes can be created but not opened.

### 9.3 Behavior to expect
- **The guest's `/dev` is a tmpfs,** so hand-made nodes vanish when the guest restarts. Recreate them at each guest boot with `tmpfiles.d` in the guest:
  ```
  # /etc/tmpfiles.d/devices.conf  (in the guest)
  c /dev/kvm 0660 root kvm - 10:232
  ```
- **Nothing populates `/dev` automatically,** because udevd is masked in the guest. A disk or USB device hotplugged on the host won't appear in the guest until its node is created. Get the major:minor numbers from the host (`ls -l /dev/sdb`) or from `/sys/class/*/*/dev` in the guest. Reading that still works with host-managed sysctls (section 7.1), where `/sys` is read-only.
- **Seccomp doesn't affect this.** With a filter on, `mknod` would still be allowed, because the guest has `CAP_MKNOD`.

---

## 10. Running Incus inside the guest

Incus works inside this guest, including **unprivileged** Incus containers. It needs a few additions, because Incus/LXC containers are nested one level inside the nspawn guest.

### 10.1 Requirements on the nspawn side

| Need | What to do |
|---|---|
| **Writable `/proc/sys`** | Keep `Environment=SYSTEMD_NSPAWN_API_VFS_WRITABLE=1` in `guest.service`. Incus writes per-interface sysctls itself as it creates `incusbr0` (e.g. `/proc/sys/net/ipv6/conf/incusbr0/disable_ipv6`) and treats a failure as fatal. Presetting them on the host can't work, because the bridge doesn't exist yet. **The host-managed sysctl option (section 7.1) is therefore incompatible with Incus.** |
| Kernel modules | The guest has no `CAP_SYS_MODULE`. Add to the host's `/etc/modules-load.d/guest.conf`: `overlay`, `tun`, `vhost_net`, `vhost_vsock`, plus `br_netfilter` if used and `kvm_intel`/`kvm_amd` for VMs. |
| Device nodes | Allowed already (`DevicePolicy=auto` + `CAP_MKNOD`). Create them via the guest's tmpfiles.d (section 9.3): `/dev/kvm`, `/dev/vhost-net`, `/dev/vhost-vsock`, `/dev/fuse` (lxcfs). `/dev/net/tun` already exists. |
| Storage pool | Use the **`dir`** driver, or btrfs/zfs/lvm on a real block device whose node you create in the guest. Avoid loop-backed pools: new `/dev/loopN` nodes are created on the host and don't appear in the guest. |
| nftables | Incus manages its own tables. Under Option A (section 6.2), a guest `nftables.service` reload with `flush ruleset` wipes them until Incus restarts. Use Option B, or ensure `nftables.service` runs before `incus.service` and is never reloaded independently. |
| AppArmor | nspawn doesn't expose securityfs, so Incus runs its instances without AppArmor confinement. They work, but are less isolated than on bare metal. |
| cgroups | Fine. `Delegate=yes` gives the guest a writable cgroup v2 subtree to hand out to instances. |
| DNS on the bridge | Incus's dnsmasq binds to the `incusbr0` address in the shared namespace. That only conflicts if something on the host already listens on port 53 on that address. |

### 10.2 Unprivileged Incus containers: the kernel's visibility rule

**Symptom:** the instance fails to start, with LXC log lines like
```
Failed to mount "proc" onto "/opt/incus/lib/lxc/rootfs/proc"
Failed to mount "sysfs" on "/opt/incus/lib/lxc/rootfs/sys" with flags 0
```
and `VFS: Mount too revealing` in `dmesg`. Privileged instances (`security.privileged=true`) start fine.

**Cause:**
- An unprivileged instance runs in its own user namespace. From there, the kernel lets it mount a new `proc` or `sysfs` only if a **fully visible** instance of that filesystem already exists in the mount namespace. This is checked by `mount_too_revealing()` / `mnt_already_visible()` in `fs/namespace.c`.
- **Fully visible** means: mounted from the filesystem's root; with no locked mounts covering anything except empty directories; and the new mount is at least as restrictive in **read-only** and **atime** flags. `nosuid`/`nodev`/`noexec` aren't compared.
- When LXC creates the instance's user and mount namespaces, every mount copied from the guest becomes **locked** (it can't be unmounted from inside).
- nspawn mounts over parts of the guest's `/proc` (`/proc/sys`, `/proc/sysrq-trigger`, `/proc/kmsg`, …). Once locked, those overmounts make `/proc` count as not fully visible.
- The guest's root has no user namespace, so it can mount a fresh procfs freely. One clean copy with nothing on top satisfies the check.

**Fix, part 1: a clean procfs in the guest**

`/etc/systemd/system/unmasked-procfs.service` (inside the guest):
```ini
[Unit]
Description=Unmasked procfs for nested unprivileged containers
Before=incus.service incus.socket incus-startup.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/mkdir -p /run/unmasked/proc
ExecStart=/bin/mount -t proc proc /run/unmasked/proc
ExecStop=-/bin/umount /run/unmasked/proc

[Install]
WantedBy=multi-user.target
```
```bash
systemctl daemon-reload
systemctl enable --now unmasked-procfs.service
findmnt -R /run/unmasked/proc     # must exist and show no child mounts
```
- **Don't mount it read-only.** LXC mounts `proc` read-write, which would then be less restrictive than the only visible copy.
- A clean `sysfs` copy isn't needed. The guest's own `/sys` already passes, because its submounts (cgroup2, debugfs, configfs, tracefs, fusectl) all sit on empty mount-point directories.
- **Instances don't keep access to it.** LXC mounts `proc` before pivoting into the instance's root, and the guest's tree is dropped afterwards.
- **Check it after every guest boot.** It has been seen `inactive (dead)` while enabled. Unprivileged autostart instances fail on any boot where it didn't run.

**Fix, part 2: mount `sysfs` read-only in instances (`sys:mixed`)**

*Applies to instances with their own network namespace (bridged NICs). For host networking, see section 10.4. `sys:mixed` doesn't work there.*

LXC's default read-write `sysfs` mount (`flags 0`) is still refused. With `lxc.mount.auto = sys:mixed`, LXC mounts `sysfs` read-only, with only `/sys/devices/virtual/net` writable. A read-only request is at least as restrictive as any existing `sysfs` mount, so it passes. Instances can't write to `/sys` apart from network-device attributes. That's typical for unprivileged containers; workloads that need writable `/sys` must be privileged.

### 10.3 Setting `raw.lxc` (single and multiple lines)

**Single line: bridged instances, for all instances via the default profile:**
```bash
incus profile set default raw.lxc "lxc.mount.auto = sys:mixed"
```

**Multiple lines.** `raw.lxc` is one string, with one LXC key per line. The example is the host-networking set from section 10.4.

- **Shell, using a heredoc (verified working):**
  ```bash
  incus config set exotic-warthog raw.lxc - <<EOF
  lxc.net.0.type = none
  lxc.mount.auto =
  lxc.mount.auto = proc:rw cgroup:rw:force
  lxc.mount.entry = /sys sys none rbind,ro,create=dir 0 0
  EOF
  ```
  The `-` tells `incus config set` to read the value from stdin. The same works with `incus profile set <profile> raw.lxc -`.
- **Shell, using `$'...'` for the newlines:**
  ```bash
  incus config set <instance> raw.lxc $'lxc.net.0.type = none\nlxc.mount.auto =\nlxc.mount.auto = proc:rw cgroup:rw:force\nlxc.mount.entry = /sys sys none rbind,ro,create=dir 0 0'
  ```
- **YAML, via `incus config edit <instance>` (or `incus profile edit <profile>`):**
  ```yaml
  config:
    raw.lxc: |-
      lxc.net.0.type = none
      lxc.mount.auto =
      lxc.mount.auto = proc:rw cgroup:rw:force
      lxc.mount.entry = /sys sys none rbind,ro,create=dir 0 0
  ```

**Profile or instance:** `incus profile set <profile> raw.lxc ...` applies to every instance using that profile; `incus config set <instance> raw.lxc ...` applies to one.

**Check and remove:**
```bash
incus profile get default raw.lxc
incus config get <instance> raw.lxc
incus config show <instance> --expanded | grep -A3 raw.lxc   # effective value
incus config unset <instance> raw.lxc
```

⚠️ **An instance's `raw.lxc` replaces the profile's value, rather than merging with it.** If an instance sets its own `raw.lxc`, it must repeat every line it needs from the profile, including `lxc.mount.auto = sys:mixed`.

If both bridged and host-networked instances will exist, put the host-networking set in its own profile (e.g. `hostnet`) rather than `default`.

### 10.4 Host networking for unprivileged instances (`lxc.net.0.type = none`)

With `none`, the instance gets **no network namespace of its own**. It shares the nspawn guest's network namespace, which is the **host's** namespace in this design. So the instance sees and uses the host's interfaces directly.

**The working configuration (verified):**
```
lxc.net.0.type = none
lxc.mount.auto =
lxc.mount.auto = proc:rw cgroup:rw:force
lxc.mount.entry = /sys sys none rbind,ro,create=dir 0 0
```

**Symptom without it.** Using `sys:mixed` with `none` fails:
```
Failed to mount "sysfs" onto "/opt/incus/lib/lxc/rootfs/proc/sys"
Failed to mount "sysfs" on "/opt/incus/lib/lxc/rootfs/proc/sys" with flags 14
```
This time there's **no** `VFS: Mount too revealing` in `dmesg`. The target path looks odd because of how LXC labels its automatic mount steps; any `sysfs` mount fails the same way.

**Cause: a second kernel rule, separate from the visibility rule.** To mount a new `sysfs`, the caller needs `CAP_SYS_ADMIN` over the **network namespace** it's in, because sysfs shows that namespace's interfaces.
- **Bridged instances** have their own network namespace, owned by their own user namespace, so container root passes.
- **With `none`**, the instance is in the host's network namespace, owned by the initial user namespace. Container root (an unprivileged mapped UID) has no capabilities there, so every `sysfs` mount gets `EPERM`. No flag or `sys:` option avoids this.

**What each line does:**

| Line | Purpose |
|---|---|
| `lxc.net.0.type = none` | No network namespace; share the guest's (= host's). |
| `lxc.mount.auto =` | An empty value **clears** the automatic mount list Incus generated. There's no `sys:none` option, so this is the only way to drop the `sys` entry. |
| `lxc.mount.auto = proc:rw cgroup:rw:force` | Re-adds everything except `sys`. Copy the `proc` and `cgroup` options Incus actually generates: `grep lxc.mount.auto /run/incus/<instance>/lxc.conf`. |
| `lxc.mount.entry = /sys sys none rbind,ro,create=dir 0 0` | **Bind-mounts** the guest's `/sys` instead. A bind doesn't create a new sysfs instance, so the network-namespace rule doesn't apply. Its contents are correct, because the instance shares that network namespace anyway. |

The clean-procfs unit (section 10.2, part 1) is still required: `proc:rw` is still subject to the visibility rule.

**Inside the instance:**
- **`/sys` is read-only.** Even without `ro`, container root maps to an unprivileged UID and couldn't write host-owned attributes.
- **The instance's systemd logs harmless failures** when it tries to mount things under `/sys` (configfs, debugfs, fuse connections). Mask those in the instance image if the noise bothers you.
- **Check it:** `incus exec <instance> -- ip -br link` should list the host's interfaces.

**Other consequences of `none`:**
- **Remove the NIC device** from wherever `raw.lxc` sets `none` (profile or instance): `incus profile device remove default eth0`. Otherwise Incus also generates its own `lxc.net.0` settings for that NIC.
- **The instance can't reconfigure host networking.** An unprivileged instance's root has no `CAP_NET_ADMIN` over the host's namespace. Its own network services (systemd-networkd, cloud-init's network stage, resolved) fail or do nothing; disable them in the instance image if the errors are noisy.
- **Low ports.** Binding ports below 1024 needs `CAP_NET_BIND_SERVICE` over the host's namespace, which unprivileged instances don't have. Use high ports, or lower `net.ipv4.ip_unprivileged_port_start` (a global sysctl, set in the guest or on the host).
- **Port collisions:** the host, the guest and every `none` instance share one port space.
- **`incusbr0` isn't needed** for these instances.

### 10.5 Diagnostics for nested-mount failures

```bash
# Kernel's reason (visibility check vs. other EPERM)
dmesg -C; incus start <instance>; dmesg | tail -n 5     # "VFS: Mount too revealing"?
#   present -> visibility rule (section 10.2)
#   absent, sysfs EPERM, instance uses lxc.net.0.type = none -> network-namespace rule (section 10.4)

# What automatic mounts did Incus generate?
grep lxc.mount.auto /run/incus/<instance>/lxc.conf

# Is the clean proc present? Is the sysfs superblock rw?
findmnt -R /run/unmasked
findmnt -o TARGET,VFS-OPTIONS,FS-OPTIONS -t sysfs

# Does incusd share the guest's mount namespace?
readlink /proc/self/ns/mnt /proc/"$(pgrep -o incusd)"/ns/mnt

# Reproduce an unprivileged mount without Incus
unshare --user --map-root-user --mount --pid --fork \
  sh -c 'mkdir -p /tmp/p && mount -t proc proc /tmp/p && echo PROC-OK'
unshare --user --map-root-user --mount --net --pid --fork \
  sh -c 'mkdir -p /tmp/t && mount -t sysfs sysfs /tmp/t && echo SYSFS-OK'

# LXC trace log
incus config set <instance> raw.lxc "lxc.log.level=trace"   # replaces any existing raw.lxc!
incus start <instance>
less /var/log/incus/<instance>/lxc.log
```
**Fallback:** `incus config set <instance> security.privileged=true` skips the user namespace, so it skips the visibility check. Root in that instance is real root on the host.

---

## 11. Things not to do

| Don't | Why |
|---|---|
| Bind the host's `/proc` | The guest's init would see the host's PID 1 as `/proc/1`; process tracking breaks. |
| Bind the host's `/sys` | It exposes the host's whole cgroup tree, and the guest's systemd would try to manage it. `/sys/class/net` is already the host's via the shared network namespace. |
| Bind the host's `/dev` wholesale | Unneeded with `CAP_MKNOD` + `DevicePolicy=auto`. Bind specific nodes (`--bind=/dev/kvm`) if you prefer. |
| `SystemCallFilter=` in `[Service]` | It restricts nspawn and the guest instead of loosening them. |
| `kernel.modules_disabled=1` | Global and one-way. It would block the host's own module loads until reboot. |
| `flush ruleset` (host or guest) | Wipes the other side's rules. |
| Mix iptables-legacy and iptables-nft | Both appear to work; the result is very hard to debug. |
| Override `systemd-nspawn@.service` | Its defaults (`--network-veth`, `-U`) contradict this design. |

---

## 12. First run checklist

1. Extract the rootfs (section 3) and apply the guest cleanup (section 4).
2. Check it without booting: `systemd-nspawn -D /var/lib/machines/guest`.
3. Install the unit and start it: `systemctl enable --now guest`.
4. Get a shell: `machinectl shell guest`.
5. Inside the guest:
   - `systemctl --failed` shows anything else to mask;
   - `systemctl is-system-running`.
6. On the host, verify:
   - `ip -br link` shows the guest's bridges;
   - `nft list tables` shows both the host's and the guest's tables;
   - `sysctl <key>` shows any values the guest set.
7. Stop and start the guest and confirm its network setup is idempotent.

---

## 13. Going further: deployable images

- **Single-file images:** a raw GPT or squashfs image with `--image=` instead of `--directory=`. That allows atomic swap and rollback: drop in `guest-v2.raw`, repoint the unit, restart. squashfs keeps xattrs but has no ACL support.
- **Throwaway writes:** `--volatile=overlay` puts a tmpfs overlay over the image, so all changes are lost on stop.
- **Reproducible builds instead of cloning:** capture `apt-mark showmanual`, `dpkg --get-selections`, apt sources and keys, and the needed `/etc` config. Then rebuild with `debootstrap` or, better, `mkosi`, which produces a directory, tar or raw image from a config file.

---

## 14. Decisions and open questions

**Decided**
- Kernels will drift. The host owns all module loading, and the guest carries no kernel or modules (sections 4, 8).
- Seccomp is off via `SYSTEMD_SECCOMP=0` (section 5).
- Traffic is essentially never destined for the host. The host has no firewall of its own, and guest rules live mostly on `forward`/`bridge` hooks (sections 2, 6.2).
- The host runs nothing except nspawn, so there are no host services to order against the guest.
- No teardown on stop; reboot the host for a clean slate (section 6.5).
- One guest per host.

- The guest can create network devices and device nodes with the current unit (section 9).
- Incus runs in the guest. Unprivileged Incus containers need the clean-procfs unit (section 10.2). Bridged instances also need `lxc.mount.auto = sys:mixed` (section 10.2). Host-networked instances need the `none` + cleared `lxc.mount.auto` + `/sys` bind set (section 10.4). `/proc/sys` must stay writable while Incus manages networks (section 10.1).

**Still open**
- [ ] Incus instances: `lxc.net.0.type = none` for all instances (profile), or only some (per instance)?
- [ ] Is `br_netfilter` actually needed, or is the nft `bridge` family enough?
- [ ] How will the guest be accessed: `machinectl shell` from the host only, or sshd on a non-22 port?
- [ ] How will the host itself be managed (SSH, console, BMC)? The guest's `input` rules must not lock it out.
- [ ] Rollback and versioning: directory + tar, or single-file images?