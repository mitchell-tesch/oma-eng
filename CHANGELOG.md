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
- GitHub issue templates (`.github/ISSUE_TEMPLATE/`).
- CI now runs `dotnet restore` on `HelloSpaceGass.csproj` and
  `pip install --dry-run` on every `requirements.txt` alongside the
  existing `validate-config.sh` checks.

### Changed

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

- Broken Omarchy manual link in doc 10
  (`learn.omacom.io/2/the-omarchy-manual/28-windows-vm` → 
  `omarchy.org/manual/windows-vm`).
- `windows-eng.xml` XML comment could not contain `--vcpupin` inline
  (double-hyphen disallowed inside XML comments); reworded to prose.
