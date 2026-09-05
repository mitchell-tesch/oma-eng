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
- **CPU pinning** — the XML template ships with the `<vcpu>` and
  `<cputune>` block deliberately commented out so `virsh define`
  won't accept a placeholder that mis-pins to your host's cores.
  Generate a correct block for your machine and paste it in:

  ```bash
  scripts/detect-host.sh --vcpupin
  ```

  That walks live `lscpu -e` output, reserves 2 physical cores for
  Omarchy, and prints a ready-to-paste `<vcpu>` + `<cputune>` +
  `<iothreads>` block. Verify with `lstopo` (`hwloc` package) if
  you want a visual topology map before pasting. Rule of thumb:
  give the guest whole physical cores + their SMT/HT siblings on the
  same CCX / P-core cluster, and leave at least 2 physical cores for
  the host.
- **PCI addresses of the Nvidia dGPU** — from `lspci -nn -D`. Both the
  VGA function (`.0`) and the audio function (`.1`).
- **Disk source path** — to the qcow2 you just created.
- **ISO paths** — the Windows ISO and virtio-win.iso for install.
- **Virtiofs source** — set to the absolute path of `src/` in this
  cloned repo, e.g. `/home/mitchell/src/oma-eng/src`.

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
  the virtio-win CD → `viostor\w11\amd64`. The virtio SCSI/block driver
  appears. Load it.
- Also load `NetKVM\w11\amd64` for the network card.
- Skip the network/Microsoft-account step by pressing
  `Shift+F10` at the "Let's connect you to a network" screen and running
  `OOBE\BYPASSNRO` (or `start ms-cxh:localonly` on newer builds).
- Create a local account. Don't sign in to a Microsoft account for the
  CAD box — it complicates dongle drivers and licence servers.

## 6. First boot after install

Log in, then from the virtio-win ISO run:

- `virtio-win-guest-tools.exe` — installs all remaining virtio drivers,
  balloon, serial, viofs (virtiofs), qxldod display.
- Reboot.

You should now see `Z:` in Explorer pointing at `src/oma-eng/src`
on the host. If you don't, see [09 — Troubleshooting](09-troubleshooting.md)
*virtiofs share doesn't appear*.

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
