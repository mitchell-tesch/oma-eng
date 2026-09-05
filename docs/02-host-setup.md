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

## 1. Install the required packages

Omarchy already has base-devel, git, and a fair amount of virt tooling.
Fill in the missing bits, choosing the microcode package that matches
your CPU:

```bash
# Common packages (both Intel and AMD hosts)
sudo pacman -S --needed \
    qemu-full libvirt virt-manager virt-viewer \
    edk2-ovmf swtpm dnsmasq iptables-nft bridge-utils \
    dmidecode \
    linux-headers

# Then ONE of these, matching your CPU:
sudo pacman -S --needed intel-ucode      # Intel hosts
sudo pacman -S --needed amd-ucode        # AMD hosts
```

Not sure which? Run `scripts/detect-host.sh` — it prints the right
package name for you.

Looking Glass gets installed in [doc 04](04-looking-glass.md) — either
via `yay -S looking-glass` (yay ships with Omarchy) or built from
source with our helper.

Enable and start libvirt:

```bash
sudo systemctl enable --now libvirtd.socket
sudo usermod -aG libvirt,kvm "$USER"
newgrp libvirt
```

Log out / back in so the group change takes effect for your shell.

Optional: raise the libvirtd resource limits so it can happily open
the many vfio, evdev, and virtiofs handles the CAD guest needs.

```bash
sudo systemctl edit libvirtd
# Paste the contents of configs/systemd/libvirtd.override.conf, save.
sudo systemctl restart libvirtd.socket libvirtd.service
```

## 2. Edit the kernel command line (Limine)

The IOMMU needs to be turned on at boot via a kernel parameter. The
parameter name depends on your CPU vendor — everything else in this
step is identical between Intel and AMD.

Locate the main Omarchy boot entry:

```bash
sudoedit /boot/limine.conf
```

You'll see one or more entries of the form:

```
/Omarchy Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: cryptdevice=UUID=... root=/dev/mapper/... rw rootflags=subvol=@ ...
    module_path: boot():/initramfs-linux.img
```

Append these to the existing `cmdline:` line for the main Omarchy
entry (single space between existing params and the new ones,
everything on one line):

**Intel hosts:**

```
intel_iommu=on iommu=pt default_hugepagesz=1G hugepagesz=1G hugepages=24
```

**AMD hosts:**

```
amd_iommu=on iommu=pt default_hugepagesz=1G hugepagesz=1G hugepages=24
```

The only difference is `intel_iommu=on` vs `amd_iommu=on`. On modern
kernels AMD IOMMU is often enabled implicitly by `iommu=pt`, but being
explicit is safer.

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
([`windows-cad.xml`](../configs/libvirt/windows-cad.xml),
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

You should see the Nvidia VGA + Audio functions alone in their group, or
grouped only with their PCIe root port. If the group contains unrelated
devices (network card, SATA controller), see
[09 — Troubleshooting](09-troubleshooting.md) *IOMMU group mixing*.

## 5. Force the Nvidia card off the host driver at boot

Two mechanisms working together:

**a) Blacklist the Nvidia driver on the host** — you don't want it, since
the iGPU is your only display. Skip this if you don't have the proprietary
Nvidia driver installed on the host anyway, but it's cheap insurance.

Copy [`configs/modprobe.d/vfio.conf`](../configs/modprobe.d/vfio.conf) to
`/etc/modprobe.d/vfio.conf`. **Substitute the vendor:device pairs your
card actually reports** — `10de:2504,10de:228e` below is one specific
RTX 3080 mobile; yours will differ. Run
`scripts/list-pci-for-passthrough.sh 10de` to print the pairs to paste.

```
# Bind Nvidia PCI IDs to vfio-pci
options vfio-pci ids=10de:2504,10de:228e disable_vga=1

# Keep the open-source and proprietary nvidia drivers off the host
blacklist nouveau
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
```

**b) Rebuild the initramfs** so vfio-pci is available before udev picks a
driver.

The only change we need is to add the vfio modules to the `MODULES=`
line of your existing `/etc/mkinitcpio.conf`. **Do not paste over
`HOOKS=`** — Omarchy installs use `encrypt` / `sd-encrypt`, `lvm2`,
`plymouth`, `btrfs`, etc. in HOOKS depending on your install choices;
losing those turns a LUKS box into a boot brick.

Two safe options:

**Option 1 — edit `/etc/mkinitcpio.conf` in place.** Add the three
vfio modules to the existing `MODULES=(…)` line:

```
MODULES=(vfio_pci vfio vfio_iommu_type1 <keep whatever was already here>)
```

Confirm your existing `HOOKS=(…)` already includes `modconf` and
`keyboard` (Omarchy's default does — this is just a sanity check).
Leave everything else in HOOKS untouched.

**Option 2 — use a mkinitcpio.conf.d drop-in** (mkinitcpio v39+, which
Arch and current Omarchy ship). Install
[`configs/mkinitcpio.d/vfio.conf`](../configs/mkinitcpio.d/vfio.conf)
to `/etc/mkinitcpio.conf.d/vfio.conf`. The drop-in uses `MODULES+=`
(append), so it can't overwrite what's in the main file.

The vfio modules load before autodetect finds `nvidia`, so the dGPU is
never claimed by the wrong driver. `kms` is already in Omarchy's
default HOOKS after `modconf`, so `nvidia_drm` load options from
`/etc/modprobe.d/vfio.conf` are honoured.

Regenerate:

```bash
sudo mkinitcpio -P
```

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

## 7. Reboot

```bash
sudo reboot
```

## 8. Verify the binding

```bash
lspci -nnk -d 10de:2504
# ...
#   Kernel driver in use: vfio-pci
#   Kernel modules: nouveau, nvidia_drm, nvidia
```

`Kernel driver in use: vfio-pci` on **both** the VGA and Audio functions
is the goal.

If it says `nouveau` or `nvidia`, either the initramfs didn't rebuild, the
IDs are wrong, or the `blacklist` lines didn't take. See doc 09.

## 9. Optional: CPU governor helper

For CAD/FEA work you want `performance` on VM cores. The helper script:

```bash
sudo install -m 755 scripts/cpu-governor /usr/local/bin/cpu-governor
sudo cpu-governor performance
```

To have the governor swap automatically when the CAD guest starts and
stops, install the libvirt qemu hook shipped in this repo:

```bash
sudo install -D -m 755 configs/libvirt/hooks/qemu /etc/libvirt/hooks/qemu
sudo systemctl restart libvirtd.service
```

The hook only fires for the `windows-cad` domain; other guests are
untouched.

## Exit criteria

- `lspci -nnk -d 10de:2504` shows `Kernel driver in use: vfio-pci`.
- `grep Huge /proc/meminfo` shows the reserved pages.
- `virsh -c qemu:///system list` runs without needing sudo.
- `dmesg | grep -i vfio` shows successful vfio-pci probes with no errors.

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
