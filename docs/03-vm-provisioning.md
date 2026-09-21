# 03 — VM provisioning

Goal: create a Windows 11 guest with the Nvidia dGPU passed through, CPU
pinning + hugepages, virtio devices, virtiofs share for the source tree,
and evdev hotkey input passthrough. We don't wire up Looking Glass yet —
that's [04](04-looking-glass.md). For the install we use SPICE.

## 1. Downloads

Put these in `~/vm-iso/`:

- **Windows 11 ISO** — from Microsoft's official download page.
- **virtio-win.iso** — from Fedora:
  <https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso>

## 2. Storage

Two reasonable options:

**A) qcow2 image on a fast NVMe (recommended default)**

```bash
sudo mkdir -p /var/lib/libvirt/images
sudo qemu-img create -f qcow2 -o preallocation=metadata,cluster_size=1M \
    /var/lib/libvirt/images/windows-cad.qcow2 200G
```

**B) Dedicated NVMe passthrough** — pass the block device directly for
close-to-native disk perf. Add a `<hostdev>` block for the NVMe controller
in the guest XML instead of a `<disk>`. Note this consumes an entire drive.

## 3. Copy and edit the guest XML template

```bash
cp configs/libvirt/windows-cad.xml /tmp/windows-cad.xml
$EDITOR /tmp/windows-cad.xml
```

Placeholders to change (search for `EDIT:` for XML-comment markers and
`CHANGEME` for path strings — both are used in the template):

- **UUID** — the template omits `<uuid>` deliberately; libvirt
  auto-generates one at `virsh define` time. If you need to pin the
  UUID (licence lock, Windows activation ID) add it back with
  `uuidgen`.
- **Memory** — must match what you reserved in hugepages. Repo default
  is 24 GiB (Rhino + Strand7 + Excel/Office). Use 16 GiB for Rhino-only
  work, 32 GiB+ for heavy FEA or large Excel dashboards. See
  [10 — Office integration](10-office-integration.md).
- **CPU pinning** — the shipped XML has a pinning block filled in for
  the machine it was last generated on. Regenerate one for your host:

  ```bash
  scripts/detect-host.sh --vcpupin
  ```

  That walks live `lscpu -e` output, classifies cores by MAXMHZ (so
  Intel hybrid P/E/LP-E CPUs are separated correctly), reserves 1
  top-tier core for Hyprland + Looking Glass + virtiofsd, and prints
  a ready-to-paste `<vcpu>` + `<cputune>` + `<iothreads>` block plus a
  matching `<topology>` hint for the `<cpu>` element. Verify with
  `lstopo` (`hwloc` package) if you want a visual topology map before
  pasting. Rule of thumb: give the guest whole physical cores + their
  SMT/HT siblings on the same CCX / P-core cluster, and leave at
  least one top-tier core for the host.
- **PCI addresses of the Nvidia dGPU** — from
  `scripts/list-pci-for-passthrough.sh 10de`. Desktop cards expose a
  VGA function (`.0`) plus an audio function (`.1`); add one
  `<hostdev>` per function. Muxless mobile Optimus cards expose only
  a single 3D controller — the template's second (audio) `<hostdev>`
  block ships commented out for that case; leave it commented for a
  muxless card. The script prints an advisory to tell you which
  applies to your host.
- **Disk source path** — to the qcow2 you just created.
- **ISO paths** — the Windows ISO and virtio-win.iso for install.
- **Virtiofs source** — set to the absolute path of `src/` in this
  cloned repo, e.g. `$HOME/src/oma-eng/src`.
- **Evdev keyboard + mouse paths** — the `<qemu:commandline>` block at
  the bottom of the XML has two `evdev=/dev/input/by-id/usb-CHANGEME-…`
  entries. Only USB HID devices have stable `/dev/input/by-id/`
  symlinks; a laptop's built-in keyboard/trackpad go through i8042/i2c
  and don't. Plug in an external USB keyboard and mouse (or pair a
  wireless pair to a Unifying/Lightspeed receiver), then run:

  ```bash
  scripts/list-evdev-for-passthrough.sh          # enumerate
  scripts/list-evdev-for-passthrough.sh --xml    # ready-to-paste block
  ```

  The `--xml` form prints the complete `<qemu:commandline>` block with
  both device paths filled in. Paste it over the CHANGEME block. Press
  both **Ctrl** keys simultaneously in the running guest to toggle
  input focus between host and guest.

## 4. Define, autostart the network, and start

```bash
sudo virsh net-start default
sudo virsh net-autostart default
virsh --connect qemu:///system define /tmp/windows-cad.xml
virsh --connect qemu:///system start windows-cad
virt-viewer --connect qemu:///system windows-cad
```

`virt-viewer` gives you a SPICE window to complete the Windows install.
Looking Glass is not connected yet.

## 5. During Windows install

- When Windows can't see any drive: click *Load driver* → *Browse* →
  the virtio-win CD → `vioscsi\w11\amd64`. *"Red Hat VirtIO SCSI
  pass-through controller"* appears in the driver list. Load it. This
  template uses the `virtio-scsi-pci` controller (see `<controller
  type='scsi' model='virtio-scsi'>` in the XML), so the driver is
  `vioscsi`. The older `viostor` driver only applies to `virtio-blk`
  disks (`bus='virtio'`) and won't make the disk appear here.
- Also load `NetKVM\w11\amd64` for the network card.
- Skip the network/Microsoft-account step by pressing
  `Shift+F10` at the "Let's connect you to a network" screen and running
  `OOBE\BYPASSNRO` (or `start ms-cxh:localonly` on newer builds).
- Create a local account. Don't sign in to a Microsoft account for the
  CAD box — it complicates dongle drivers and licence servers.

## 6. First boot after install

Log in, then from the virtio-win ISO run:

- `virtio-win-guest-tools.exe` — installs the balloon, serial,
  viofs (virtiofs), qxldod display, and virtio guest agent. Reboot
  when prompted.

**Modern virtio-win (0.1.29x+) gotchas.** The bundled installer no
longer pulls in WinFsp, and can quietly skip NetKVM on Windows 11.
Verify after the reboot — each of these has bitten fresh installs:

1. **Device Manager → Other devices** should be empty. If you see
   *Ethernet Controller*, *PCI Simple Communications Controller*,
   *Base System Device*, or *PCI Device* with a yellow triangle,
   right-click each → *Update driver → Browse my computer* → point
   at the virtio-win CD root; Windows finds the matching folder
   (`NetKVM\w11\amd64`, `vioserial\w11\amd64`, `Balloon\w11\amd64`,
   etc.). The one exception is *3D Video Controller* — that's the
   passthrough dGPU and needs the Nvidia driver in step 7.

2. **`ipconfig /all`** in `cmd` should show an IPv4 address of
   `192.168.122.x` with `Default Gateway 192.168.122.1`. If it shows
   `169.254.x.x` (APIPA) with an empty gateway, either NetKVM didn't
   install (fix per bullet 1), or your Omarchy host is running UFW
   and hasn't whitelisted `virbr0` — fix on the host per
   [02 — Host setup](02-host-setup.md) §10 and re-run
   `ipconfig /release && ipconfig /renew` in the guest.

3. **`Z:` drive** should appear in Explorer pointing at
   `~/dev/oma-eng/src` on the host. If it doesn't, open `services.msc`
   → *VirtIO-FS Service* → try to Start. If it errors with *Error
   1053: service did not respond in a timely fashion*, the WinFsp
   filesystem framework isn't installed — download the MSI from
   [https://winfsp.dev](https://winfsp.dev), install it (Typical),
   then Start the service. Drive letter is auto-assigned; look for
   the drive labelled `src` if it isn't `Z:`.

## 7. Install the Nvidia driver (in the guest)

- Grab the latest **Nvidia Studio Driver** for your card from
  <https://www.nvidia.com/Download/index.aspx> — Studio is more stable for
  CAD than Game Ready.
- Install with *Clean install* checked.
- Reboot. Device Manager should show the Nvidia card without warnings.
  `nvidia-smi` in an admin PowerShell should list the GPU.
- If Device Manager shows *Code 43*, see doc 09.

## 8. Enable Remote Desktop and OpenSSH (optional but nice)

For headless / VS Code Remote workflows:

```powershell
# In an admin PowerShell on the guest
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True `
    -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
```

Add an SSH public key to `C:\ProgramData\ssh\administrators_authorized_keys`
(and set ACL to Administrators + SYSTEM only — see doc 08).

## 9. Test the GPU inside the guest

```powershell
nvidia-smi
dxdiag                       # look at Display tab
```

Also run 3DMark's free demo or WebGL Aquarium in Edge as a smoke test —
frame rate should be within a couple of percent of bare-metal.

## 10. Snapshot before you touch anything else

```bash
virsh --connect qemu:///system snapshot-create-as windows-cad clean-install \
    "Windows + virtio + Nvidia + SSH, before Rhino/Strand7"
```

## Exit criteria

- `virsh list` shows `windows-cad` `running`.
- SPICE console works, guest boots into Windows 11.
- Device Manager shows the Nvidia card, no warnings, `nvidia-smi` works.
- `Z:\` mounts the host `src/` tree.
- `ssh windows-cad` from Omarchy works (after adding a host entry in
  `~/.ssh/config`).

Continue to [04 — Looking Glass](04-looking-glass.md) for the seamless
display.
