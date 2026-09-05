# oma-eng

**Omarchy for structural engineers.** Running **Rhino 8**, **Strand7 R3**,
**CSi ETABS 22**, **SpaceGass 14**, and **Microsoft Office** on **Omarchy**
(Arch Linux + Hyprland) with full GPU acceleration and a working
API-development workflow.

None of these applications ship a native Linux build, and each has a real
automation surface (RhinoCommon / Grasshopper, Strand7 COM, ETABS OAPI,
SpaceGass COM/batch, Excel Interop). Any approach that runs them under
Wine trades away correctness on the API and stability on the GUI. This
repo takes the other path: run a **Windows 11 guest under KVM/QEMU with
VFIO GPU passthrough**, integrated seamlessly into Hyprland via
**Looking Glass**, and drive it from Omarchy as if it were a native
application.

## Architecture

```
+----------------------------------- Omarchy host (Arch + Hyprland) -----------------------------------+
|                                                                                                      |
|   Intel iGPU (i915) OR AMD iGPU (amdgpu)     Nvidia dGPU                                             |
|   drives Hyprland                <-- bound to vfio-pci at boot -->     Windows 11 guest (QEMU/KVM)  |
|                                                                        |                             |
|                                                                        |  Rhino 8   Grasshopper      |
|   Looking Glass client       <=== IVSHMEM shared memory (KVMFR) ====>  |  Strand7 R3   ETABS 22      |
|   (Hyprland window)                                                    |  SpaceGass 14   Excel       |
|                                                                        |  Nvidia driver + CUDA/OptiX |
|                                                                        |                             |
|   VS Code (Remote-SSH)       <========= virtio-net (NAT) ============> |  OpenSSH + VS Code Server   |
|                                                                        |                             |
|   ~/src/oma-eng              <========= virtiofs share =============>  |  Z:\src (same tree in guest)|
|                                                                                                      |
+------------------------------------------------------------------------------------------------------+
```

You edit C#/Python plugin code on Omarchy with your normal tools; the guest
sees the same files instantly via virtiofs, builds them with the real Rhino
SDK / Strand7 COM / ETABS OAPI, and displays the result inside a Hyprland
window.

## Prerequisites (confirmed for this repo)

- **CPU: Intel OR AMD** with hardware virtualisation and IOMMU
  (VT-x + VT-d for Intel; SVM + AMD-Vi for AMD)
- Integrated GPU driving the Omarchy desktop
  (Intel iGPU on `i915` **or** AMD iGPU on `amdgpu` — both work identically)
- **Nvidia dGPU** dedicated to the guest (Turing / Ampere / Ada tested paths)
- ≥ 32 GB RAM (24 GB guest for Rhino + Strand7 + Excel is the repo default;
  bump to 32 GB guest if you add ETABS to the mix — see
  [docs/10-office-integration.md](docs/10-office-integration.md) and
  [docs/11-etabs-and-spacegass.md](docs/11-etabs-and-spacegass.md))
- Fast SSD/NVMe for the guest image (or a whole spare NVMe passed through)
- Valid Windows 11 license, valid app licences (Rhino, Strand7, ETABS,
  SpaceGass — see doc 11 for licence-server / dongle passthrough options)
- **Omarchy quattro (4.x)** already installed. Limine bootloader (Omarchy
  default since 2.0). If you're on an older Omarchy still on
  systemd-boot, see the fallback notes at the bottom of
  [docs/02-host-setup.md](docs/02-host-setup.md).

Not sure what CPU / iGPU / dGPU your machine actually has? After
Omarchy is installed, run [scripts/detect-host.sh](scripts/detect-host.sh)
for a full report — it prints the exact kernel cmdline and microcode
package your host needs.

## Why not `omarchy windows vm`?

Omarchy ships a built-in Windows VM feature (*Install ▸ Windows* in the
Omarchy menu, or `omarchy windows vm launch`). It runs Windows 11 Pro
in a Docker container (Dockur) and connects over RDP. It's a great
answer for Office / general Windows use.

However, the Omarchy manual is explicit: *"There's no GPU passthrough
with this setup, so it's not suitable for gaming or video editing."*
Rhino's viewport and Strand7's OpenGL renderer both need real GPU
acceleration, and Cycles/OptiX rendering in Rhino needs CUDA. That
rules out the built-in path for our use case.

This repo builds the alternative: libvirt/KVM with **VFIO GPU
passthrough** to a dedicated Windows guest, plus Looking Glass for
seamless display integration.

## Install path

Follow the docs in order — each one leaves the system in a verifiable state
before the next one begins.

1. [Hardware & BIOS prep](docs/01-hardware-prep.md)
2. [Host (Omarchy) preparation](docs/02-host-setup.md)
3. [VM provisioning](docs/03-vm-provisioning.md)
4. [Looking Glass for seamless display](docs/04-looking-glass.md)
5. [Windows guest tuning](docs/05-windows-guest.md)
6. [Rhino 8 + Grasshopper setup](docs/06-rhino-setup.md)
7. [Strand7 R3 setup](docs/07-strand7-setup.md)
8. [API development workflow](docs/08-api-development.md)
9. [Troubleshooting playbook](docs/09-troubleshooting.md)
10. [Office / Excel integration](docs/10-office-integration.md) — where to run Excel and why
11. [CSi ETABS + SpaceGass](docs/11-etabs-and-spacegass.md) — additional structural packages, licence dongles, APIs

## Repo layout

```
docs/       Ordered walk-through of the whole setup
scripts/    Idempotent helpers you run on the Omarchy host
configs/    Config templates you copy into /etc/... on the host and edit
src/        API sample projects; this directory is virtiofs-mounted into the guest
```

## Success criteria

You'll know the setup is done when all of these are true:

- `virsh list` shows `windows-cad` running.
- Looking Glass shows the Windows desktop inside a Hyprland window with
  < 5 ms added latency and no tearing.
- Inside the guest, `nvidia-smi` sees the dGPU and Rhino's
  `SystemInfo` command reports it as the OpenGL device.
- Strand7 → *Tools ▸ Preferences ▸ Graphics* reports the Nvidia GPU
  and the built-in `TESTOGL.ST7` runs at monitor refresh.
- ETABS → *Help ▸ System Info* and SpaceGass → *Settings ▸ Preferences
  ▸ Display* both report the Nvidia GPU as the active renderer.
- Excel → *File ▸ Options ▸ Advanced ▸ Display* has *Disable hardware
  graphics acceleration* **unticked**, and Excel's viewport interacts
  with the Nvidia GPU under load (visible in `nvidia-smi` running in
  the guest).
- `Z:\src` in the guest lists the same files as `~/src/oma-eng/src`
  on the host, and edits from Omarchy appear immediately.
- `code --remote ssh-remote+windows-cad` from Omarchy opens a working
  VS Code session in the guest, with C# IntelliSense against
  `RhinoCommon.dll` and `ETABSv1.dll`.

## Non-goals

- Running any of Rhino, Strand7, ETABS, SpaceGass, or Office directly
  under Wine. Grasshopper, Strand7 COM, ETABS OAPI, SpaceGass
  automation, and Excel Interop all fall over there; this is a
  dead-end for API work.
- Nested virtualisation, cloud GPU instances, or WSL. All add latency,
  cost, or lose GPU access to the real hardware.
- Persuading McNeel, Strand7 Pty Ltd, CSi, StruSoft, or Microsoft to
  ship native Linux binaries. That would obsolete this whole repo —
  happy day if it happens.

## Licence

MIT — see [LICENSE](LICENSE). Third-party components (Rhino, Strand7,
ETABS, SpaceGass, Office, Looking Glass host application, Windows) are
subject to their own licences and are not distributed here.
