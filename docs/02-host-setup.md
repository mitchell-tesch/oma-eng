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

## 1. Run the host-prep script

[`scripts/prepare-host.sh`](../scripts/prepare-host.sh) idempotently
installs every package this repo needs (QEMU, libvirt, virt-manager,
edk2-ovmf, swtpm, dnsmasq, libxml2, the vfio/mkinitcpio drop-ins, and
the matching CPU microcode), installs `cpu-governor` +
`/etc/libvirt/hooks/qemu` so the governor swaps automatically around
guest start/stop, drops a Hyprland Looking Glass config in
`~/.config/hypr/looking-glass.conf` if a Hyprland config dir exists,
adds you to the `libvirt` and `kvm` groups, enables `libvirtd.socket`
and `virtlogd.socket`, and rebuilds the initramfs.

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
sudo ./scripts/set-cmdline                    # apply (24 GiB hugepages)
sudo ./scripts/set-cmdline --hugepages 32     # apply with a different size
sudo ./scripts/set-cmdline --no-regen         # skip limine-update
```

Rebooting is still up to you.

Manual alternative (Omarchy 4.x path), if you want to inspect the
files yourself:

```bash
sudoedit /etc/limine-entry-tool.d/vfio.conf
```

Add a single append line:

**Intel hosts:**

```bash
KERNEL_CMDLINE[default]+=" intel_iommu=on iommu=pt default_hugepagesz=1G hugepagesz=1G hugepages=24"
```

**AMD hosts:**

```bash
KERNEL_CMDLINE[default]+=" amd_iommu=on iommu=pt default_hugepagesz=1G hugepagesz=1G hugepages=24"
```

The leading space in the string is intentional — `+=` concatenates
without a separator, and `KERNEL_CMDLINE[default]` already ends in a
non-space token from `/etc/default/limine`.

Verify the composed cmdline before rebuilding the UKI:

```bash
sudo limine-entry-tool --get-cmdline linux --no-mutex --no-hooks
```

That should end in `... hugepages=24`. Then rebuild the UKI +
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
  16 for Rhino-only, **24 for Rhino + Strand7 + Excel/Office** (this
  repo's default), 32+ for heavy FEA or large Excel dashboards. If
  you'd rather manage hugepages via sysctl, skip this and install
  [`configs/sysctl.d/99-vm-hugepages.conf`](../configs/sysctl.d/99-vm-hugepages.conf)
  instead.

The guest memory value is quietly duplicated in three files
([`windows-eng.xml`](../configs/libvirt/windows-eng.xml),
[`99-vm-hugepages.conf`](../configs/sysctl.d/99-vm-hugepages.conf),
[`hugepages.service`](../configs/systemd/hugepages.service)) plus
this kernel cmdline. Rather than edit each by hand, use
[`scripts/set-guest-memory`](../scripts/set-guest-memory) — it
retargets the three repo files atomically and prints the exact
`hugepages=N` value to paste here:

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
# 01:00.0 VGA compatible controller [0300]: NVIDIA Corporation ... [10de:2504] (rev a1)
# 01:00.1 Audio device [0403]: NVIDIA Corporation ...             [10de:228e] (rev a1)
```

The interesting bit is `[10de:2504]` and `[10de:228e]`. Both must be bound
to vfio-pci. If your card also exposes USB-C or an extra function (some
RTX cards have a USB controller at `.2`), include those too.

Write these into `/etc/modprobe.d/vfio.conf` in the next step — that's
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
# Bind Nvidia PCI IDs to vfio-pci
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
> every duplicated field in sync in one shot — the three repo files, the
> installed `/etc/sysctl.d/` drop-in (via `sudo install` + `sysctl
> --system`), and the libvirt persistent config for `windows-eng` (via
> `virsh setmaxmem`/`setmem --config` for a defined guest, or `virsh
> define` for a fresh install). limine.conf stays manual by design.
> Pass `--no-apply` to touch only the repo files, or `--dry-run` to
> diff without changing anything.

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

## 9. CPU governor (installed automatically by prepare-host.sh)

For CAD/FEA work you want `performance` on VM cores. `prepare-host.sh`
installed [`scripts/cpu-governor`](../scripts/cpu-governor) at
`/usr/local/bin/cpu-governor` and
[`configs/libvirt/hooks/qemu`](../configs/libvirt/hooks/qemu) at
`/etc/libvirt/hooks/qemu`, so the governor swaps to `performance`
when the `windows-eng` domain starts and back to `schedutil` when it
stops — nothing else to do.

Manual usage if you want to swap without the guest running:

```bash
sudo cpu-governor performance    # for CAD/FEA use
sudo cpu-governor schedutil      # Arch default
sudo cpu-governor status         # show current
```

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

## Exit criteria

- `lspci -nnk -d 10de:2504` shows `Kernel driver in use: vfio-pci`.
- `grep Huge /proc/meminfo` shows the reserved pages.
- `virsh -c qemu:///system list` runs without needing sudo.
- `dmesg | grep -i vfio` shows successful vfio-pci probes with no errors.
- If UFW or firewalld is active, `virbr0` is whitelisted (see §10) —
  `sudo ufw status verbose | grep virbr0` (UFW) or
  `sudo firewall-cmd --get-zone-of-interface=virbr0` (firewalld)
  returns a matching rule / the `libvirt` zone.

If any of these fail, do not proceed — fix here first.

## Other bootloaders

If you're on a pre-2.0 Omarchy still using **systemd-boot**, the same
kernel params go into the `options` line of your boot entry under
`/boot/loader/entries/*_linux.conf` (find the active one with
`sudo bootctl status`). Everything else is identical.

If you're on **GRUB** (custom install), edit `/etc/default/grub`'s
`GRUB_CMDLINE_LINUX_DEFAULT=...`, then `sudo grub-mkconfig -o
/boot/grub/grub.cfg`. Everything else is identical.

Continue to [03 — VM provisioning](03-vm-provisioning.md).
