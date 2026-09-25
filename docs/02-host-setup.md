# 02 — Host (Omarchy) setup

Goal: leave the Omarchy host with (a) IOMMU enabled, (b) the Nvidia GPU
early-bound to `vfio-pci` so no host driver ever touches it, (c) libvirt +
QEMU installed and running, and (d) hugepages reserved for the guest.

Works on both **Intel** and **AMD** hosts. Vendor-specific bits (kernel
cmdline, microcode package) are called out where they differ; run
[scripts/detect-host.sh](../scripts/detect-host.sh) at any point to
print a report of what your machine actually is and what config it
needs.

Written and tested against **Omarchy quattro (4.x)** with the **Limine**
bootloader (default since Omarchy 2.0). If you're on an older Omarchy
release still using systemd-boot, or on GRUB, see the fallback notes at
the end of this document — the concepts are identical, only the
bootloader edit differs.

## 0. Update the system first

Use Omarchy's update mechanism, not raw pacman — it takes a snapshot
first so you can roll back cleanly if anything goes sideways:

```bash
omarchy update
```

(Or *Update ▸ Omarchy* from the Omarchy menu with `Super + Space`.)
Reboot if the kernel updated.

Then take one more snapshot, right before this doc changes the kernel
command line, initramfs and drivers. It appears under **Snapshots** in
the Limine boot menu, so you can boot back to it if a later step leaves
the host unbootable ([Undo and rollback](#undo-and-rollback)):

```bash
omarchy-snapshot create
```

## 1. Run the host-prep script

Run everything from the repo root at `~/dev/oma-eng` (see the README's
*Install path*; the guest share and `Z:\oma-eng\` paths depend on it).

[`scripts/prepare-host.sh`](../scripts/prepare-host.sh) idempotently
installs every package this repo needs (QEMU, libvirt, virt-manager,
edk2-ovmf, swtpm, dnsmasq, libxml2, the vfio/mkinitcpio drop-ins, and
the matching CPU microcode), installs `cpu-governor` +
`/etc/libvirt/hooks/qemu` (performance profile + sleep inhibitor while
the guest runs) and the `libvirt-guests` config for clean guest
shutdown, drops a Hyprland Looking Glass config in
`~/.config/hypr/` (`looking-glass.lua` on Omarchy quattro's Lua config,
`looking-glass.conf` on older Hyprland) if a Hyprland config dir exists,
adds you to the `libvirt` and `kvm` groups, enables `libvirtd.socket`
and `virtlogd.socket`, and rebuilds the initramfs. On a muxless laptop
dGPU it prints a hint to re-run with `--kvmfr` once you reach doc 04 §2b.

**On Omarchy the installer offers to enable the Nvidia driver during
setup, and enabling it puts `nvidia`, `/etc/modprobe.d/nvidia.conf` and
`/etc/mkinitcpio.conf.d/nvidia.conf` on disk. Those race with vfio-pci
for the dGPU at boot.** `prepare-host.sh` detects this and prints a
warning. You have two options:

- **Path A (recommended when the dGPU is dedicated to the guest):** let
  the script uninstall `nvidia-open-dkms` and its drop-ins so vfio-pci
  is the only claimant. You lose host-side CUDA/OptiX; you gain a
  deterministic boot and trivial recovery.
- **Path B:** keep the Nvidia stack on host and write a `libvirt` prepare/
  release hook that unbinds `nvidia` and binds `vfio-pci` on guest
  start. Not shipped in this repo; only pick this if you actually use
  host-side CUDA.

Run the script. Add `--remove-nvidia` if you're taking Path A:

```bash
sudo ./scripts/prepare-host.sh --dry-run                    # preview
sudo ./scripts/prepare-host.sh --remove-nvidia              # Path A
sudo ./scripts/prepare-host.sh                              # Path B (warns only)
```

Log out and back in so the group additions take effect for your shell.

Optional: raise libvirtd's file-descriptor and locked-memory limits so
it can hold every vfio, evdev, and virtiofs handle the CAD guest needs:

```bash
sudo systemctl edit libvirtd
# Paste the contents of configs/systemd/libvirtd.override.conf, save.
sudo systemctl restart libvirtd.socket libvirtd.service
```

Looking Glass itself gets installed in [doc 04](04-looking-glass.md).

## 2. Edit the kernel command line

The IOMMU needs to be turned on at boot via a kernel parameter, and
libvirt wants 1 GiB hugepages reserved for the guest. Both are
cmdline tokens.

On Omarchy 4.x the source of truth for the kernel command line is
**`/etc/default/limine`** — specifically the `KERNEL_CMDLINE[default]`
bash-array variable that `limine-entry-tool` composes at UKI-build
time. Drop-ins under `/etc/limine-entry-tool.d/*.conf` append extra
tokens. **`/etc/kernel/cmdline` is completely ignored on such a
system** even though it looks like it should work — editing it is a
silent no-op because `limine-entry-tool` never reads it when
`KERNEL_CMDLINE[default]` is defined. This has burnt many an Omarchy
user; the helper below deals with it for you.

Easiest: run the helper. It detects the Omarchy `KERNEL_CMDLINE[default]`
setup, drops our tokens into `/etc/limine-entry-tool.d/vfio.conf` in
the append syntax the tool expects, then runs `limine-update` to
rebuild the UKI + `/boot/limine.conf`. On non-Omarchy hosts it falls
back to `/etc/kernel/cmdline`, systemd-boot entries, or GRUB.

```bash
scripts/set-cmdline --status                  # what's on the running kernel?
sudo ./scripts/set-cmdline --dry-run          # preview
sudo ./scripts/set-cmdline                    # apply (hugepages = template guest RAM)
sudo ./scripts/set-cmdline --hugepages 24     # apply with a different size
sudo ./scripts/set-cmdline --no-regen         # skip limine-update
```

The hugepage count defaults to the guest RAM in
[`windows-eng.xml`](../configs/libvirt/windows-eng.xml) (32 GiB as
shipped), so the two can't drift. It refuses a count that would leave the
host under 8 GiB. **On a host with less than ~48 GB RAM, shrink the guest
first** with `scripts/set-guest-memory 16` or `24` (see §6), then run
`set-cmdline`.

Rebooting is still up to you.

Manual alternative (Omarchy 4.x path), if you want to inspect the
files yourself:

```bash
sudoedit /etc/limine-entry-tool.d/vfio.conf
```

Add a single append line (replace `32` with your guest RAM in GiB):

**Intel hosts:**

```bash
KERNEL_CMDLINE[default]+=" intel_iommu=on iommu=pt default_hugepagesz=1G hugepagesz=1G hugepages=32"
```

**AMD hosts:**

```bash
KERNEL_CMDLINE[default]+=" amd_iommu=on iommu=pt default_hugepagesz=1G hugepagesz=1G hugepages=32"
```

The leading space in the string is intentional — `+=` concatenates
without a separator, and `KERNEL_CMDLINE[default]` already ends in a
non-space token from `/etc/default/limine`.

Verify the composed cmdline before rebuilding the UKI:

```bash
sudo limine-entry-tool --get-cmdline linux --no-mutex --no-hooks
```

That should end in `... hugepages=32` (or your size). Then rebuild the UKI +
`/boot/limine.conf`:

```bash
sudo limine-update
```

Watch for the final `Copied: /tmp/limine-mkinitcpio.XXXXX/linux.efi
-> /boot/EFI/Linux/omarchy_linux.efi` line — that's the UKI actually
being written. If it prints `WARNING: Possibly missing firmware for
module: 'xhci_pci_renesas'` and `'qat_6xxx'`, ignore both — Omarchy's
initramfs config asks for those modules unconditionally and the
firmware isn't shipped.

On a non-Omarchy host you'd edit `/etc/kernel/cmdline` instead and
still run `sudo limine-update` — the `set-cmdline` helper does both
paths automatically.

To have the script print the exact line for you:

```bash
scripts/detect-host.sh --cmdline
```

That's all we need in the cmdline. Notably we do **not** put
`vfio-pci.ids=...` there — it goes into `/etc/modprobe.d/vfio.conf`
in step 5, where it's easier to change and won't be trampled by
Omarchy's snapshot regeneration.

- `intel_iommu=on` / `amd_iommu=on` — turn on the IOMMU.
- `iommu=pt` — passthrough mode (host devices skip DMA translation,
  only the passed-through devices go through IOMMU; better host perf).
- `default_hugepagesz=1G hugepagesz=1G hugepages=N` — reserve N GiB of
  1 GiB hugepages at boot. Match to your planned guest memory:
  16 for Rhino-only, 24 for Rhino + Strand7 + Excel/Office,
  **32 for + ETABS / heavy FEA** (the template's default; `set-cmdline`
  reads it from the XML). If
  you'd rather manage hugepages via sysctl, skip this and install
  [`configs/sysctl.d/99-vm-hugepages.conf`](../configs/sysctl.d/99-vm-hugepages.conf)
  instead.

The guest memory size lives in your machine's copy of the domain XML,
`configs/libvirt/windows-eng.local.xml` (gitignored; doc 03 §3 creates
it from the tracked template). `set-cmdline` reads `hugepages=N` from it.
To change the size, use
[`scripts/set-guest-memory`](../scripts/set-guest-memory) rather than
editing by hand. It updates the local XML, the installed sysctl drop-in
(if any) and libvirt's config together, then tells you to re-run
`set-cmdline`:

```bash
scripts/set-guest-memory 32               # set guest to 32 GiB
scripts/set-guest-memory 32 --dry-run     # preview diffs first
scripts/set-guest-memory --status         # what's the current setting?
```

Don't add these to the `/Omarchy Linux (snapshot ...)` entries — those
are auto-managed by `omarchy-snapshot`. If you need to boot into a
snapshot later, you'll temporarily lose IOMMU on that boot; that's OK
because the VM won't be starting anyway.

Save and exit. Limine reads `/boot/limine.conf` at boot; no regeneration
step is required.

## 3. Identify the Nvidia PCI IDs

```bash
scripts/list-pci-for-passthrough.sh
```

Or manually:

```bash
lspci -nn | grep -i -E 'nvidia|geforce|rtx|quadro'
# Example output from a desktop card (yours will differ):
# 01:00.0 VGA compatible controller [0300]: NVIDIA Corporation ... [10de:2504] (rev a1)
# 01:00.1 Audio device [0403]: NVIDIA Corporation ...             [10de:228e] (rev a1)
```

The interesting bit is the `[vendor:device]` pairs (`10de:2504` and
`10de:228e` in this example). Every function must be bound
to vfio-pci. If your card also exposes USB-C or an extra function (some
RTX cards have a USB controller at `.2`), include those too.

Write these into [`configs/modprobe.d/vfio.conf`](../configs/modprobe.d/vfio.conf)
(it ships with the author's laptop ID as an example) and re-run
`sudo ./scripts/prepare-host.sh`, which installs it to
`/etc/modprobe.d/vfio.conf` and warns if an ID matches no device. That's
where vfio-pci reads them from at module-load time. Keeping the IDs
out of the Limine cmdline means (a) your bootloader edit stays short
and readable, and (b) Omarchy snapshot regeneration can't accidentally
strip them.

## 4. Verify IOMMU groups

After the reboot in step 6, run:

```bash
scripts/check-iommu.sh
```

You should see the Nvidia device(s) alone in their group, or grouped
only with their PCIe root port. A muxless mobile Optimus card lists
only a single 3D controller (class 0302); a desktop card lists a VGA
function (0300) plus an HDMI-audio function (0403), sometimes with a
USB-C function (0c03) alongside —
[`scripts/list-pci-for-passthrough.sh 10de`](../scripts/list-pci-for-passthrough.sh)
prints an advisory when only one function is present so you don't add
a phantom `<hostdev>` later. If the group contains unrelated devices
(network card, SATA controller), see
[09 — Troubleshooting](09-troubleshooting.md) *IOMMU group mixing*.

## 5. Force the Nvidia card off the host driver at boot

[`scripts/prepare-host.sh`](../scripts/prepare-host.sh) already did
this in step 1 — it installed [`configs/modprobe.d/vfio.conf`](../configs/modprobe.d/vfio.conf)
and [`configs/mkinitcpio.d/vfio.conf`](../configs/mkinitcpio.d/vfio.conf),
and ran `mkinitcpio -P`. This section is background reference for what
those two files do, and what to check if the binding doesn't take.

Two mechanisms working together:

**a) Blacklist the Nvidia driver on the host.** The vfio.conf drop-in
contains something like:

```
# Bind Nvidia PCI IDs to vfio-pci (example: RTX A500 Laptop)
options vfio-pci ids=10de:25bb disable_vga=1

# Keep the open-source and proprietary nvidia drivers off the host
blacklist nouveau
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm

softdep nouveau pre: vfio-pci
softdep nvidia  pre: vfio-pci
```

List every function your card exposes:
[`scripts/list-pci-for-passthrough.sh 10de`](../scripts/list-pci-for-passthrough.sh)
prints them all and warns when only one function exists (muxless
mobile Optimus). Substitute the real vendor:device pairs and
re-run `sudo ./scripts/prepare-host.sh` — it detects the change and
rewrites the drop-in with a `.bak`.

**b) Rebuild the initramfs** so `vfio-pci` is available before udev
picks a driver. The mkinitcpio.d drop-in uses `MODULES+=(vfio_pci vfio
vfio_iommu_type1)` so it can't overwrite Omarchy's other `MODULES+=`
drop-ins (e.g. `nvidia.conf`, `thunderbolt_module.conf`). The
`softdep` lines and the `blacklist` above then win the load-order race
inside the initramfs.

On any host where an Omarchy install previously enabled the Nvidia
driver, [`configs/mkinitcpio.d/nvidia.conf`](../scripts/prepare-host.sh)
still sits alongside our `vfio.conf`. `prepare-host.sh --remove-nvidia`
deletes it (Path A above); without that flag both drop-ins live on
and the module load order becomes racy.

Confirm your existing `HOOKS=(…)` already includes `modconf` and
`keyboard` (Omarchy's default does — this is just a sanity check).
Leave everything else in HOOKS untouched.

## 6. Hugepages

If you set `hugepages=` in the kernel line (step 2), you're done — verify
after reboot with:

```bash
grep Huge /proc/meminfo
# HugePages_Total:      16
# Hugepagesize:   1048576 kB
```

If you prefer dynamic allocation, install
[`configs/sysctl.d/99-vm-hugepages.conf`](../configs/sysctl.d/99-vm-hugepages.conf):

```bash
sudo install -m 644 configs/sysctl.d/99-vm-hugepages.conf /etc/sysctl.d/
sudo sysctl --system
```

> **Keep the cmdline and the sysctl drop-in in sync.** These two paths
> aren't mutually exclusive — if you install the sysctl file *and* set
> `hugepages=N` on the kernel cmdline, both values must match. At every
> boot the kernel reserves N pages first (from cmdline), then
> `systemd-sysctl.service` runs and rewrites `vm.nr_hugepages` to
> whatever the drop-in says. A drift like `hugepages=32` on cmdline but
> `vm.nr_hugepages = 24` in the drop-in leaves you with 24 pages after
> boot, silently. Verification signature: `dmesg | grep -i hugetlb`
> reports the cmdline count, `/proc/meminfo` reports the sysctl count.
>
> [`scripts/set-guest-memory <GiB>`](../scripts/set-guest-memory) keeps
> them in sync in one shot. It sets `<memory>` in `windows-eng.local.xml`,
> re-renders the installed `/etc/sysctl.d/` drop-in with the new count
> (`sudo install` + `sysctl --system`), and updates the libvirt
> persistent config (`virsh setmaxmem`/`setmem --config` for a defined
> guest, or `virsh define` for a fresh install). `prepare-host.sh`
> renders the drop-in the same way. Tracked repo files are never edited.
> Pass `--no-apply` to touch only the local XML, or `--dry-run` to diff
> without changing anything; then `sudo scripts/set-cmdline` + reboot.

## 7. Reboot

```bash
sudo reboot
```

## 8. Verify the binding

```bash
scripts/list-pci-for-passthrough.sh 10de     # list Nvidia function(s)
lspci -nnk -d 10de:*                          # show driver in use
```

`Kernel driver in use: vfio-pci` on **every** Nvidia function listed
by `list-pci-for-passthrough.sh` is the goal. Desktop cards typically
list two functions (VGA + audio); muxless mobile Optimus cards list
one (a 3D controller with no audio silicon on the bus).

If it says `nouveau` or `nvidia`, either the initramfs didn't rebuild, the
IDs are wrong, or the `blacklist` lines didn't take. See doc 09.

## 9. CPU performance, sleep, and clean shutdown (installed by prepare-host.sh)

`prepare-host.sh` installs
[`configs/libvirt/hooks/qemu`](../configs/libvirt/hooks/qemu) at
`/etc/libvirt/hooks/qemu`. While `windows-eng` runs, it:

- switches power-profiles-daemon to `performance` (Omarchy ships
  power-profiles-daemon). On hosts without it, the hook calls
  [`scripts/cpu-governor`](../scripts/cpu-governor), installed at
  `/usr/local/bin/cpu-governor`. The previous profile or governor is
  restored when the guest stops.
- confines host tasks (`user.slice`, `system.slice`, `init.scope`) to
  the CPUs *not* listed in the domain's `<vcpupin>` block, so browsers,
  builds and indexers can't preempt the guest's pinned P-cores. On the
  ZBook G11 that leaves the host P-core 0 plus all E/LP-E cores
  (`0,5,12-21`), so native renders are slower while the VM is up.
  Runtime-only (`systemctl set-property --runtime`); undone when the
  guest stops. Check with `systemctl show -p AllowedCPUs user.slice`.
  On Intel hybrid laptops, `intel_lpmd` (Omarchy enables it) manages
  the same property. Its low-power mode is forced off in every
  power profile by default, but a restart of the service while the VM
  is up resets the host to all CPUs until the next guest start.
- blocks host sleep and logind's lid-close suspend. Suspending with the
  dGPU passed through leaves the guest GPU dead on resume. Closing the
  lid still locks the screen; shut the guest down before bagging the
  laptop. Check with `systemd-inhibit --list`.

It also installs [`configs/libvirt/libvirt-guests`](../configs/libvirt/libvirt-guests)
at `/etc/conf.d/libvirt-guests` and enables `libvirt-guests.service`, so
host poweroff/reboot sends the guest an ACPI shutdown (180 s timeout)
instead of killing QEMU.

Manual governor control without the guest running:

```bash
sudo cpu-governor performance
sudo cpu-governor powersave      # intel_pstate default (schedutil on acpi-cpufreq)
sudo cpu-governor status         # current + available governors
```

`intel_pstate` in active mode (the default on modern Intel) only offers
`performance` and `powersave`; `cpu-governor` rejects anything else.

## 10. Firewall (UFW / firewalld)

Omarchy ships with **UFW active by default** (deny incoming, deny
routed). Libvirt's `virbr0` bridge is treated as an external interface
by UFW, so DHCP requests and NAT'd outbound traffic from the guest are
silently dropped. Symptom during doc 03 Windows install: the guest
settles on an APIPA address `169.254.x.x` instead of `192.168.122.x`,
and `/var/lib/libvirt/dnsmasq/virbr0.status` stays empty (dnsmasq is
listening but never sees the DHCP DISCOVER).

**UFW** (Omarchy default):

```bash
UPLINK=$(ip -4 route show default | awk '/^default/ {print $5; exit}')
sudo ufw allow in on virbr0
sudo ufw route allow in on virbr0 out on "$UPLINK"
sudo ufw reload
sudo ufw status verbose | grep -E 'virbr0|FWD'
```

`$UPLINK` is your host's outbound interface — Wi-Fi (`wlp*`), wired
ethernet (`enp*`), or a USB-C dock. The `awk` inline picks it up
automatically from the current default route.

**firewalld** (if you swapped Omarchy's default):

```bash
sudo firewall-cmd --zone=libvirt --add-interface=virbr0 --permanent
sudo firewall-cmd --reload
```

Check which firewall is active first with
`systemctl is-active ufw firewalld`. If both come back `inactive`, the
guest will DHCP fine without any of this.

## 11. SSD TRIM through LUKS

Omarchy's full-disk encryption does not pass discards through dm-crypt
by default, so neither the host nor the guest's `discard='unmap'` ever
TRIMs the NVMe. Over time that degrades SSD write speed. Check:

```bash
lsblk --discard | grep crypt    # DISC-GRAN 0B = discards blocked
```

LUKS2 can store the flag in its header, so there's no kernel cmdline edit
and the change takes effect immediately:

```bash
sudo cryptsetup refresh --allow-discards --persistent root
sudo cryptsetup luksDump /dev/nvme0n1p2 | grep Flags    # allow-discards
sudo systemctl enable --now fstrim.timer                # weekly
sudo fstrim -v /                                        # first pass now
```

Trade-off: an attacker with the raw disk can see which blocks are unused
(filesystem type and rough fill level); file contents stay encrypted.
From the next reboot btrfs also enables `discard=async` on its own
(kernel 6.2+ does this when the device supports discard);
`fstrim.timer` is a cheap weekly safety net alongside it.

## Exit criteria

- `lspci -nnk -d 10de:` shows `Kernel driver in use: vfio-pci` for every
  Nvidia function.
- `grep Huge /proc/meminfo` shows the reserved pages.
- `virsh -c qemu:///system list` runs without needing sudo.
- `dmesg | grep -i vfio` shows successful vfio-pci probes with no errors.
- If UFW or firewalld is active, `virbr0` is whitelisted (see §10) —
  `sudo ufw status verbose | grep virbr0` (UFW) or
  `sudo firewall-cmd --get-zone-of-interface=virbr0` (firewalld)
  returns a matching rule / the `libvirt` zone.

If any of these fail, do not proceed — fix here first.

## Undo and rollback

### Host won't boot after a cmdline or initramfs change

1. In the Limine boot menu, open **Snapshots** and boot the one from §0.
   If only the initramfs changed (vfio drop-ins), the **fallback** entry
   may also get you in.
2. From the booted snapshot, either make it permanent with
   `omarchy-snapshot restore`, or fix forward on the normal entry by
   removing what `set-cmdline` added:

   ```bash
   sudo rm /etc/limine-entry-tool.d/vfio.conf    # Omarchy 4.x drop-in
   sudo limine-update
   ```

   On other bootloaders `set-cmdline` left a timestamped `.bak` next to
   the file it edited; copy it back.

The usual cause is a `hugepages=` count too large for the host's RAM.
`set-cmdline` refuses those, but hand edits don't.

### Give the dGPU back to the host

For when you want CUDA or the Nvidia driver on Linux again (the VM then
can't use the card):

```bash
sudo rm /etc/modprobe.d/vfio.conf /etc/mkinitcpio.conf.d/vfio.conf
grep -E '\[ALPM\] removed nvidia' /var/log/pacman.log   # what --remove-nvidia removed
sudo pacman -S <those packages>
sudo mkinitcpio -P && sudo limine-update && sudo reboot
```

To return the hugepage RAM too, delete `hugepages=`,
`default_hugepagesz=1G` and `hugepagesz=1G` from
`/etc/limine-entry-tool.d/vfio.conf`, then
`limine-update`. The IOMMU tokens are harmless to keep.

### Revert the guest

With the VM shut off:

```bash
virsh -c qemu:///system snapshot-list windows-eng --tree
virsh -c qemu:///system snapshot-revert windows-eng <name>
```

Cloud licences activated after that snapshot may ask you to sign in
again. Snapshots live inside the qcow2, so they don't protect against
losing the disk; see [doc 13](13-collaboration-and-backup.md) for backups.

### Remove everything

```bash
V="virsh -c qemu:///system"
$V destroy windows-eng 2>/dev/null
$V undefine windows-eng --nvram --tpm --snapshots-metadata
sudo rm /var/lib/libvirt/images/windows-eng.qcow2

# Installed by prepare-host.sh / set-cmdline. Where prepare-host replaced
# an existing file it left <file>.bak.<timestamp>: restore that instead.
sudo rm -f /etc/modprobe.d/vfio.conf /etc/mkinitcpio.conf.d/vfio.conf \
    /etc/sysctl.d/99-vm-hugepages.conf /etc/conf.d/libvirt-guests \
    /etc/libvirt/hooks/qemu /usr/local/bin/cpu-governor \
    /etc/modules-load.d/kvmfr.conf /etc/modprobe.d/kvmfr.conf \
    /etc/udev/rules.d/99-kvmfr.rules /etc/limine-entry-tool.d/vfio.conf
sudo systemctl disable --now libvirt-guests.service
sudo ufw delete allow in on virbr0
sudo ufw route delete allow in on virbr0 out on "$UPLINK"   # $UPLINK as in §10
rm -f ~/.config/hypr/looking-glass.lua   # and its require(...) line in hyprland.lua
sudo mkinitcpio -P && sudo limine-update && sudo reboot
```

Also, by hand:

- the `# Added by oma-eng` `cgroup_device_acl` block at the end of
  `/etc/libvirt/qemu.conf` (from `--kvmfr`);
- the `@libvirt-images` line in `/etc/fstab` and the subvolume itself
  (doc 03 §2);
- the `.desktop` launcher from doc 04 §6;
- group membership: `sudo gpasswd -d $USER libvirt` and `kvm`.

Leave LUKS `allow-discards` (§11) on: it's independent of the VM.

## Other bootloaders

If you're on a pre-2.0 Omarchy still using **systemd-boot**, the same
kernel params go into the `options` line of your boot entry under
`/boot/loader/entries/*_linux.conf` (find the active one with
`sudo bootctl status`). Everything else is identical.

If you're on **GRUB** (custom install), edit `/etc/default/grub`'s
`GRUB_CMDLINE_LINUX_DEFAULT=...`, then `sudo grub-mkconfig -o
/boot/grub/grub.cfg`. Everything else is identical.

Continue to [03 — VM provisioning](03-vm-provisioning.md).
