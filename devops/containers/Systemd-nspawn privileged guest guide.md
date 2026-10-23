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
| `/proc/sys`, `/sys` | Writable (`SYSTEMD_NSPAWN_API_VFS_WRITABLE=1`). |
| Devices | `DevicePolicy=auto`. With `CAP_MKNOD` the guest can create any node it needs. |
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
| `nftables.service` | The stock config does `flush ruleset`, which would wipe the host's rules. |
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
- ⚠️ The guest's writable `/proc/sys` includes `kernel.modprobe`. A guest could repoint it and break the host's autoloading. That's accepted as part of trusting the guest; alternatively, have the host set it after the guest starts.

---

## 9. Things not to do

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

## 10. First run checklist

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

## 11. Going further: deployable images

- **Single-file images:** a raw GPT or squashfs image with `--image=` instead of `--directory=`. That allows atomic swap and rollback: drop in `guest-v2.raw`, repoint the unit, restart. squashfs keeps xattrs but has no ACL support.
- **Throwaway writes:** `--volatile=overlay` puts a tmpfs overlay over the image, so all changes are lost on stop.
- **Reproducible builds instead of cloning:** capture `apt-mark showmanual`, `dpkg --get-selections`, apt sources and keys, and the needed `/etc` config. Then rebuild with `debootstrap` or, better, `mkosi`, which produces a directory, tar or raw image from a config file.

---

## 12. Decisions and open questions

**Decided**
- Kernels will drift. The host owns all module loading, and the guest carries no kernel or modules (sections 4, 8).
- Seccomp is off via `SYSTEMD_SECCOMP=0` (section 5).
- Traffic is essentially never destined for the host. The host has no firewall of its own, and guest rules live mostly on `forward`/`bridge` hooks (sections 2, 6.2).
- The host runs nothing except nspawn, so there are no host services to order against the guest.
- No teardown on stop; reboot the host for a clean slate (section 6.5).
- One guest per host.

**Still open**
- [ ] Is `br_netfilter` actually needed, or is the nft `bridge` family enough?
- [ ] How will the guest be accessed: `machinectl shell` from the host only, or sshd on a non-22 port?
- [ ] How will the host itself be managed (SSH, console, BMC)? The guest's `input` rules must not lock it out.
- [ ] Rollback and versioning: directory + tar, or single-file images?