# Changelog

All notable changes to this repository are captured here. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-09-25

First public release: a guide for running Windows CAD/FEA software in a
KVM/QEMU guest on [Omarchy](https://omarchy.org), with the Nvidia dGPU
passed through (VFIO) and the display shown on the host via Looking Glass.

### Guide (`docs/`)

- **Core setup (01–05):**
  - hardware and firmware prep, with a *Desktop or laptop?* table for
    muxless laptop dGPUs;
  - host setup, with an *Undo and rollback* section;
  - VM provisioning;
  - Looking Glass;
  - Windows guest tuning.

  The README has an ordered setup checklist that links every step.
- **Per-app docs (06–07, 10–13):** Rhino 8 + Grasshopper, Strand7 R3,
  Office/Excel, CSi ETABS + SAP2000 + SPACE GASS, Revit +
  Rhino.Inside.Revit + pyRevit, Bluebeam and collaboration/backup. Each
  covers licensing models that work in a VM, GPU verification, and API
  entry points.
- **08:** the API development workflow (host editor, guest build/debug,
  SSH session 0 vs the console session).
- **09:** a troubleshooting playbook with a find-by-message index.
- **14:** native Linux tooling that needs no guest: FreeCAD + IfcOpenShell,
  Bonsai, Jupyter + handcalcs.

### Host tooling (`scripts/`)

- `prepare-host.sh`: idempotent host setup. It covers packages, vfio drop-ins,
  the libvirt hook, `libvirt-guests`, groups and initramfs, and warns when
  `vfio.conf` IDs match no device. `--kvmfr` handles the Looking Glass
  kvmfr setup for muxless laptops.
- `set-cmdline`: IOMMU + hugepages on the kernel command line (Omarchy
  Limine drop-in, with systemd-boot/GRUB fallbacks). It reads the page
  count from the guest XML and refuses to starve the host.
- `set-guest-memory` and `set-guest-share`: change guest RAM or virtiofs
  shares, and sync the local XML, sysctl drop-in and libvirt.
- `detect-host.sh`, `check-iommu.sh`, `list-pci-for-passthrough.sh` and
  `list-evdev-for-passthrough.sh` inspect the host; `detect-host.sh
  --vcpupin` generates CPU pinning.
- `install-looking-glass.sh`, `launch-windows-eng` (start the VM and open
  or focus Looking Glass) and `cpu-governor`.
- `validate-config.sh` checks XML, shell (bash -n + shellcheck), Python,
  `.csproj` and every doc link and `#anchor`. It runs in CI.

### Configuration (`configs/`)

- **`libvirt/windows-eng.xml`**, a generic domain template. Each machine
  keeps its real config in a gitignored `windows-eng.local.xml`, which
  every script prefers. The template sets up:
  - 1 GiB hugepages, Q35 + OVMF Secure Boot and TPM 2.0;
  - Hyper-V enlightenments, with the hypervisor bit visible and `vmx`
    hidden;
  - virtio-scsi on an SSD-flagged disk, with no balloon;
  - one virtiofs share (`~/dev` → `Z:\`).
- **`libvirt/hooks/qemu`** runs while the guest is up. It switches the
  power profile to performance, blocks host sleep and lid suspend, and
  confines host tasks to the CPUs outside the guest's pinning. All three
  are undone on stop.
- `libvirt/libvirt-guests`: clean ACPI guest shutdown on host poweroff.
- vfio, mkinitcpio, hugepages sysctl, kvmfr and udev drop-ins, the Looking
  Glass client config (with SPICE audio), and Hyprland window rules in
  Lua (quattro) and `.conf` form.

### Samples (`src/`)

- Rhino plugin (`HelloRhino`) and Grasshopper component (`HelloGh`).
- Strand7 C# + Python, ETABS C# OAPI (`HelloETABS`), and a SAP2000 port
  guide.
- SPACE GASS REST (C# + Python).
- Excel via xlwings and a Rhino→Excel plugin.
- IFC column dump and a handcalcs beam-capacity notebook.

Python samples use `uv` with committed lockfiles. The C# samples ship
VS Code launch configs where they apply.

### Project

- `SECURITY.md` threat model, including the risks of the read-write
  `~/dev` share. `CONTRIBUTING.md`, issue templates, and a GitHub
  Actions workflow: `validate-config.sh`, `uv lock --check`, `dotnet
  restore`.

### Known limitations

- Verified end-to-end on one machine: an HP ZBook Firefly G11
  (Core Ultra 7 165H, RTX A500 Laptop, muxless). The desktop dGPU path
  follows standard VFIO practice and is documented, but hasn't been
  re-verified for this release.
- The template's `<vcpupin>` block is for that 165H. Regenerate it with
  `scripts/detect-host.sh --vcpupin` on any other CPU.
- Written against Omarchy quattro 4.x with Limine. Other Arch setups and
  bootloaders are covered by fallback notes, not tested.
- Windows-only C# samples (the Rhino/Grasshopper ones) aren't built in
  CI; there is no Windows runner.
- Tested with Omarchy 4.0.4, Linux 7.2, Hyprland 0.56, QEMU 11.1,
  libvirt 12.7, Looking Glass B7, Windows 11 25H2, Rhino 8 SR35,
  Strand7 R3.1, ETABS 23, SAP2000 26 and SPACE GASS 14.5.

[Unreleased]: https://github.com/mitchell-tesch/oma-eng/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mitchell-tesch/oma-eng/releases/tag/v0.1.0
