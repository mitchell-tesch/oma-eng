# oma-eng

**Omarchy for structural engineers.** Running **Rhino 8**, **Strand7 R3**,
**CSi ETABS 22**, **CSi SAP2000 26**, **SpaceGass 14**, **Autodesk Revit**
(with Rhino.Inside.Revit + pyRevit), **Bluebeam Revu**, and **Microsoft
Office** on **Omarchy** (Arch Linux + Hyprland) with full GPU
acceleration and a working API-development workflow — plus a set of
open-source tools (**Bonsai / BlenderBIM**, **Jupyter + Handcalcs**)
that run natively on Omarchy when you don't need the guest.

None of the Windows-native applications above ship a native Linux
build, and each has a real automation surface (RhinoCommon /
Grasshopper, Strand7 API, ETABS + SAP2000 OAPI, SpaceGass REST,
Revit API, Bluebeam Actions, Excel Interop). Any approach that runs
them under Wine trades away correctness on the API and stability on
the GUI. This repo takes the other path: run a **Windows 11 guest
under KVM/QEMU with VFIO GPU passthrough**, integrated seamlessly
into Hyprland via **Looking Glass**, and drive it from Omarchy as if
it were a native application.

## Architecture

```
+----------------------------------- Omarchy host (Arch + Hyprland) -----------------------------------+
|                                                                                                      |
|   Intel iGPU (i915) OR AMD iGPU (amdgpu)     Nvidia dGPU                                             |
|   drives Hyprland                <-- bound to vfio-pci at boot -->     Windows 11 guest (QEMU/KVM)  |
|                                                                        |                             |
|                                                                        |  Rhino 8   Grasshopper      |
|   Looking Glass client       <=== IVSHMEM shared memory (KVMFR) ====>  |  Strand7 R3   ETABS 22      |
|   (Hyprland window)                                                    |  SAP2000 26     SpaceGass   |
|                                                                        |  Revit + Rhino.Inside       |
|                                                                        |  pyRevit    Bluebeam Revu   |
|                                                                        |  Excel + Office             |
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
SDK / Strand7 API / ETABS OAPI / Revit API / pyRevit, and displays the
result inside a Hyprland window.

## Prerequisites (confirmed for this repo)

- **CPU: Intel OR AMD** with hardware virtualisation and IOMMU
  (VT-x + VT-d for Intel; SVM + AMD-Vi for AMD)
- Integrated GPU driving the Omarchy desktop
  (Intel iGPU on `i915` **or** AMD iGPU on `amdgpu` — both work identically)
- **Nvidia dGPU** dedicated to the guest (Turing / Ampere / Ada tested paths)
- ≥ 32 GB RAM (24 GB guest for Rhino + Strand7 + Excel is the repo default;
  bump to 32 GB guest if you add ETABS, 40+ GB if you also run Revit — see
  [docs/10-office-integration.md](docs/10-office-integration.md),
  [docs/11-etabs-and-spacegass.md](docs/11-etabs-and-spacegass.md), and
  [docs/12-revit-and-rhino-inside.md](docs/12-revit-and-rhino-inside.md))
- Fast SSD/NVMe for the guest image (or a whole spare NVMe passed through)
- Valid Windows 11 license, valid app licences (Rhino, Strand7, ETABS,
  SAP2000, SpaceGass, Revit, Bluebeam Revu — see doc 11 for
  licence-server / dongle passthrough options and doc 13 for corporate
  licence servers + VPN topology). CSi ETABS and SAP2000 share the
  same Reprise licence pool.
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
11. [CSi ETABS + SAP2000 + SpaceGass](docs/11-etabs-and-spacegass.md) — additional structural packages, licence dongles, APIs
12. [Revit + Rhino.Inside.Revit + pyRevit](docs/12-revit-and-rhino-inside.md) — BIM authoring and its plugin ecosystem
13. [Bluebeam Revu + collaboration workflows](docs/13-collaboration-and-backup.md) — drawing markup, cloud storage, VPN, corporate licence servers, backup
14. [Native Omarchy tooling](docs/14-native-omarchy-tooling.md) — open-source (Bonsai/BlenderBIM + Jupyter/Handcalcs) for the work that doesn't need the guest

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
- ETABS → *Help ▸ System Info* reports the Nvidia GPU; SAP2000
  → *Help ▸ About SAP2000* likewise; SpaceGass → *Settings ▸
  Preferences ▸ Display* reports the Nvidia GPU as the active renderer.
- Excel → *File ▸ Options ▸ Advanced ▸ Display* has *Disable hardware
  graphics acceleration* **unticked**, and Excel's viewport interacts
  with the Nvidia GPU under load (visible in `nvidia-smi` running in
  the guest).
- If installed: Revit → *File ▸ Options ▸ Graphics* reports the Nvidia
  GPU; Rhino.Inside.Revit's *Start* button opens Grasshopper inside the
  Revit process without warnings; pyRevit's ribbon tab loads.
- If installed: Bluebeam Revu opens PDFs from the virtiofs share and
  can sign into Bluebeam Studio (Prime or hosted) from the guest.
- Optional native Omarchy tooling (doc 14): Bonsai add-on loads in
  Blender and opens IFC files with a populated spatial tree; `jupyter
  lab` launches and a `%%render` cell with Handcalcs produces LaTeX
  output.
- `Z:\src` in the guest lists the same files as `~/src/oma-eng/src`
  on the host, and edits from Omarchy appear immediately.
- `code --remote ssh-remote+windows-cad` from Omarchy opens a working
  VS Code session in the guest, with C# IntelliSense against
  `RhinoCommon.dll`, `ETABSv1.dll`, `SAP2000v1.dll` (if installed),
  and `RevitAPI.dll` (if installed).

## Non-goals

- Running any of Rhino, Strand7, ETABS, SAP2000, SpaceGass, Revit,
  Bluebeam, or Office directly under Wine. Grasshopper, Strand7 API,
  ETABS + SAP2000 OAPI, SpaceGass automation, Revit API, Bluebeam
  Actions, and Excel Interop all fall over there; this is a
  dead-end for API work.
- Nested virtualisation, cloud GPU instances, or WSL. All add latency,
  cost, or lose GPU access to the real hardware.
- Persuading McNeel, Strand7 Pty Ltd, CSi, StruSoft, Autodesk,
  Bluebeam, or Microsoft to ship native Linux binaries. That would
  obsolete this whole repo — happy day if it happens.

## Licence

MIT — see [LICENSE](LICENSE). Third-party components (Rhino, Strand7,
ETABS, SpaceGass, Office, Looking Glass host application, Windows) are
subject to their own licences and are not distributed here.
