# Changelog

All notable changes to this repository are captured here. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Doc 12 covering **Autodesk Revit** with **Rhino.Inside.Revit** and
  **pyRevit** installation, licence, GPU verification, API
  workflow, and cross-integration with Rhino / ETABS / Strand7 /
  SpaceGass / Excel.
- Doc 13 covering **Bluebeam Revu**, cloud storage (OneDrive,
  Aconex, Procore, Dropbox, Autodesk Docs), VPN topology (host vs
  guest), corporate licence servers (Autodesk NLM, Reprise, Sentinel,
  CodeMeter, FlexNet, Tekla, Studio Prime), and a backup-strategy
  matrix.
- Doc 14 covering native Omarchy open-source tooling — **Bonsai**
  (formerly BlenderBIM) with IfcOpenShell for BIM/IFC work, and
  **Jupyter + Handcalcs** for engineering calc notebooks.
- **SAP2000** added to doc 11 (retitled *CSi ETABS + SAP2000 +
  SpaceGass*) — install steps, shared CSi Reprise licence pool,
  OAPI comparison table, two-line HelloETABS→HelloSAP2000 port.
- `src/sap2000-api/README.md` documenting the ETABS→SAP2000 port
  pattern.
- `CONTRIBUTING.md`, `SECURITY.md`, and this `CHANGELOG.md`.
- `scripts/set-guest-memory` helper — atomically updates guest RAM
  across `windows-eng.xml`, `99-vm-hugepages.conf`, and
  `hugepages.service`; prints the `/boot/limine.conf` snippet to
  edit by hand.
- `scripts/set-guest-share` helper — lists / adds / removes
  `<filesystem>` blocks in `windows-eng.xml`, hot-attaches (or
  detaches) the PCI device on the running guest via `virsh
  attach-device --live --config`, and prints the paired guest-side
  `sc.exe create VirtioFsSvc-<tag>` snippet needed because
  `virtiofs.exe` handles one tag per service instance. `--letter`
  pins the guest drive letter (`-m Z:`) instead of leaving the
  service to race for one (`-m *`).
- GitHub issue templates (`.github/ISSUE_TEMPLATE/`).
- CI now runs `dotnet restore` on `HelloSpaceGass.csproj` and
  `pip install --dry-run` on every `requirements.txt` alongside the
  existing `validate-config.sh` checks.

### Changed

- **Virtiofs consolidated to a single share.** `configs/libvirt/windows-eng.xml`
  now ships one `<filesystem>` block: `~/dev` (tag `dev`) at `Z:\` in
  the guest. The briefly-shipped two-share layout (`src` at `Z:\`,
  `dev` at `Y:\`) needed one Windows service per tag, both services
  defaulted to `-m *` (first free letter counting down from `Z:`), and
  whichever won the startup race took `Z:` — so the two letters could
  swap between boots. Consequences:
  - This repo's source tree is now `Z:\oma-eng\src\`, not `Z:\`.
    Every path reference in docs 03–13, the READMEs, `.gitignore`, and
    `HelloETABS/Program.cs` rewritten accordingly. Sibling repos are
    `Z:\<repo>\`.
  - The guest's *VirtIO-FS Service* must be pinned with
    `-t dev -m Z:` (doc 03 §6); the `VirtioFsSvc-Dev` companion
    service is deleted.
  - Removes an incidental hazard: the old layout exported the same
    subtree through two independent `virtiofsd` processes, both with
    `cache mode='always'`.
- **Repository renamed** from `rhino-omarchy` to `oma-eng`
  (Omarchy for engineering). All README / doc / csproj metadata /
  AssemblyInfo GitHub URLs / virtiofs paths updated.
- `configs/libvirt/windows-eng.xml`:
  - `<uuid>` element removed — libvirt now auto-generates one at
    `virsh define` time instead of accepting an all-zero placeholder.
  - `<vcpu>` and `<cputune>` blocks commented out with a big banner
    directing users to `scripts/detect-host.sh --vcpupin`. Domain
    now fails to define until the user pastes in a topology-correct
    block, rather than silently pinning to wrong host cores.
- `src/etabs-api/csharp/HelloETABS/Program.cs` — every late-bound
  COM call now passes the full argument list explicitly (dynamic
  invocation does not honour type-library defaults). Affected:
  `ApplicationStart`, `PointObj.AddCartesian`, `PointObj.SetRestraint`.
- `src/strand7-api/csharp/HelloStrand7/HelloStrand7.cs` — moved into
  its own subfolder for parity with the other C# samples;
  `SetDllDirectory` switched to `CharSet.Unicode` so non-ASCII
  `STRAND7_DIR` values work.
- `scripts/prepare-host.sh` — removed the `2>/dev/null || true`
  swallow on the mkinitcpio drop-in install so real errors surface.
- Excel GPU-check menu path in README and doc 10 corrected from
  *File ▸ Account ▸ About Excel* to
  *File ▸ Options ▸ Advanced ▸ Display*.
- Doc 04 Looking Glass version guidance softened from a hard `B7-rc1`
  pin to `<version>` placeholder plus "match host client and guest
  host-app" instructions.
- Doc 10 Office install now points at `winget search Microsoft.Office`
  + the Office Deployment Tool rather than pinning a specific package
  ID.
- Doc 06 gained a "if you're on Rhino 9" retarget note (change
  `net7.0-windows` → `net8.0-windows`, `RhinoCommon 8.*-*` → `9.*-*`).
- Doc 07 gained an explicit hot-attach recipe for
  `configs/libvirt/hasp-dongle.xml`.
- `src/office-integration/python/strand7_to_excel.py` — dead
  `try / finally: pass` removed; buffer size hoisted to
  `ERR_BUF_SIZE` constant.
- `src/strand7-api/python/hello_strand7.py` and
  `src/strand7-api/csharp/HelloStrand7/HelloStrand7.cs` — 256-byte
  buffer hoisted to `ERR_BUF_SIZE` / `ErrBufSize` constants.
- `scripts/detect-host.sh` `-h/--help` line range corrected to match
  the actual header end (lines 2-13, not 2-17).
- `.gitignore` — added Grasshopper working artefacts (`*.gh_temp`,
  `AutoSave*`, `GH_TEMP*`, `*.rhl`, `*.3dmbak`, `*.gh.bak`).

### Fixed

- **Fresh-setup blockers from a new-user review:**
  - Hugepage count now comes from the template's `<memory>` (32 GiB).
    `set-cmdline`, `detect-host.sh` and `prepare-host.sh` hard-coded 24,
    so a fresh host reserved too few pages and the VM wouldn't start.
    `set-cmdline` refuses counts that leave the host < 8 GiB. The README
    now states host RAM needs (≥ 48 GB for the 32 GiB guest; shrink
    first on smaller hosts).
  - Evdev `input-linux` args ship commented out. They were active with
    `CHANGEME` paths, so the first `virsh start` failed. Doc 04 §8 is
    now opt-in.
  - Template/doc values tied to the author's machine: the virtiofs
    source is `/home/CHANGEME/dev`; the `vfio.conf` ID is labelled as an
    example, and `prepare-host.sh` warns when its IDs match no PCI device;
    doc 02's exit check is `lspci -nnk -d 10de:`; doc 04's `.desktop`
    entry uses `$HOME`; doc 05's SSH `User` is a placeholder.
  - ISOs live in `/var/lib/libvirt/images/iso/` (QEMU can't read
    Omarchy's mode-700 home directory) and are moved in after the
    subvolume is mounted.
  - README/doc 02 say to clone to `~/dev/oma-eng`, which the single
    `Z:\` share and all guest paths assume.
  - Doc 03 exit criteria no longer require `ssh windows-eng` (set up in
    doc 05 §6), and note the harmless NVPCF device warning on laptops.
- **Hyper-V enlightenments were silently disabled.** `windows-eng.xml`
  masked the `hypervisor` CPUID bit, so Windows reported
  `HypervisorPresent = False` and ignored the entire `<hyperv>` block.
  The mask, `<kvm><hidden/>` and `vendor_id` (only needed for NVIDIA
  drivers older than R465) are gone; `runtime`, `stimer direct`,
  `tlbflush` and `ipi` added; `vmx` hidden so Windows can't start a
  slow nested hypervisor (VBS/HVCI, WSL2).
- **libvirt qemu hook never ran and couldn't restore.** The installed
  copy still matched `windows-cad`, and release set `schedutil`, which
  `intel_pstate` (active mode) doesn't offer. The hook now drives
  power-profiles-daemon (falls back to `cpu-governor`), restores the
  previous profile on stop, and holds a `sleep:handle-lid-switch`
  inhibitor while the guest runs: suspending with the dGPU passed
  through kills the guest GPU. `cpu-governor` validates against
  `scaling_available_governors`.
- The qemu hook now confines host tasks to the CPUs outside the guest's
  `<vcpupin>` set while the VM runs (runtime `AllowedCPUs` on
  `user.slice`/`system.slice`/`init.scope`), derived from the domain
  XML libvirt passes on stdin.
- **Host poweroff hard-killed the guest.** New
  `configs/libvirt/libvirt-guests` (ACPI shutdown, 180 s timeout);
  `prepare-host.sh` installs it and enables `libvirt-guests.service`.
- `scripts/launch-windows-eng` always started a second Looking Glass
  client: `pgrep -x` only matches the 15-char comm field. Now
  `pgrep -f`, and focus uses the Hyprland 0.56 Lua dispatcher by window
  address (legacy `focuswindow` fallback).
- **SSD never received TRIM.** The LUKS root blocked discards and
  `fstrim.timer` was disabled. Doc 02 §11 enables the persistent LUKS2
  `allow-discards` flag and `fstrim.timer`.
- **VM disk lived inside the snapper-managed root subvolume.** Every
  pre-update snapshot pinned and fragmented the 200 GiB qcow2, and a
  root rollback would have rolled back the Windows disk. Doc 03 §2 now
  puts `/var/lib/libvirt/images` on its own `@libvirt-images`
  subvolume (nodatacow) before creating the disk.
- **Snapshots taken before the `windows-cad` → `windows-eng` rename
  still pointed at `windows-cad.qcow2`**, so revert would fail and
  `snapshot-delete` orphaned data inside the image. Metadata rewritten;
  doc 09 documents the fix-up for future renames.
- **virtiofs `cache mode='always'` could serve stale files** to guest
  builds after edits on the host. `windows-eng.xml` and
  `set-guest-share` now omit `<cache>` so virtiofsd uses its default
  `auto` (libvirt's schema only accepts `none`/`always`).
- Doc 05 §5: keep Windows Time running (was Manual/Stopped), verify
  `HypervisorPresent`, exclude `Z:\` from Defender, and drop OneDrive /
  SharePoint sync folders from the Search index.
- Doc 05 §5: guest background-load tuning with undo commands. Covers
  Defender scan pacing (low-priority, 30% cap; real-time protection
  kept), SysMain disabled, Delivery Optimization peer downloads off, and
  Edge startup boost/background mode off.
- Doc 05 §6: reserve the guest's DHCP address (`virsh net-update …
  ip-dhcp-host`) before hard-coding it in `~/.ssh/config`.
- `scripts/validate-config.sh`: 2 min+ → ~0.4 s. Python is compiled in
  one interpreter with `.venv/` excluded and no `__pycache__` writes
  (IPython `%` magics in jupytext notebooks tolerated). Shell scripts are
  found by shebang instead of a hard-coded list (now covers
  `launch-windows-eng`, `set-guest-share`). The doc link check ignores
  code blocks.
- `scripts/prepare-host.sh` installs `looking-glass.lua` on Omarchy
  quattro's Lua Hyprland config (`.conf` otherwise) and only prints the
  `require`/`source` hint when it's missing.
- `windows-eng.xml` header and `<memtune>` example updated to the
  current 32 GiB / 10 vCPU layout.
- `windows-eng.xml`: disk reports as SSD (`rotation_rate='1'`) so
  Windows retrims instead of defragging; `<memballoon model='none'/>`
  (locked hugepages + VFIO can't balloon).
- Looking Glass client: `[spice] audio = yes`, so guest audio plays on
  the host (it previously went nowhere). Doc 04 §5.
- **Corrected the SSH-vs-Looking-Glass session story in docs 04, 08,
  and 09.** The old claim — that VirtIO-FS maps `Z:` per interactive
  session, so plain `ssh windows-eng` can't see it and needs a `net
  use` workaround — is wrong. `virtiofs.exe` runs as LocalSystem and
  publishes the mount into the global DosDevices namespace, so `Z:`
  resolves from every session. The real split is **Windows session 0
  vs the console session**: `sshd` (and therefore VS Code Remote-SSH)
  runs in session 0, which has no desktop, while Looking Glass shows
  session 1. Filesystem and build work is fine over plain SSH; only
  desktop-bound work (GUI apps, COM against a running instance,
  display settings) needs a Looking Glass PowerShell.
- Broken Omarchy manual link in doc 10
  (`learn.omacom.io/2/the-omarchy-manual/28-windows-vm` → 
  `omarchy.org/manual/windows-vm`).
- `windows-eng.xml` XML comment could not contain `--vcpupin` inline
  (double-hyphen disallowed inside XML comments); reworded to prose.
