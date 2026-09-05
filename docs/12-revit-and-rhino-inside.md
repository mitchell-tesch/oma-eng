# 12 — Revit + Rhino.Inside.Revit + pyRevit

Autodesk Revit is a Windows-only BIM platform, and for structural
engineers it's the industry-standard modelling tool for building
projects — the entry point to most downstream deliverables. Its API
surface (`RevitAPI.dll` / `RevitAPIUI.dll`) drives an enormous plugin
ecosystem, none of which runs under Wine.

This doc adds Revit and the two most useful free extensions on top of
it:

- **Rhino.Inside.Revit** — runs Rhino 8 and Grasshopper as a Revit
  add-in in the same process, so Grasshopper components can read and
  write Revit elements directly. Officially supported by McNeel.
- **pyRevit** — Python-based extension manager for Revit with
  IronPython 2 and CPython 3 script engines, hot-reload, and a large
  community library.

Read after [11 — CSi ETABS + SpaceGass](11-etabs-and-spacegass.md).
Revit adds significant RAM pressure to the existing engineering
stack, and the guest XML should be resized before you install.

## Where Revit lives

Same VFIO guest as Rhino / Strand7 / ETABS / SpaceGass / Excel.
Reasons:

- Rhino.Inside.Revit loads Rhino as a DLL into the Revit process —
  they must share a Windows session.
- Revit's DirectX 11 viewport benefits from the passed-through
  Nvidia dGPU under Looking Glass.
- Revit ↔ ETABS / SAP2000 interop via CSiXRevit needs the CSi
  runtime in the same session.
- Bluebeam markup workflows (doc 13) plug through Revit's PDF export,
  so one guest keeps the round-trip local.

## RAM sizing update

Revit is memory-hungry. Extend the ladder from
[doc 11](11-etabs-and-spacegass.md):

| Apps you routinely run at once | Guest RAM |
|---|---|
| Rhino only | 16 GiB |
| Rhino + Strand7 + Excel (repo default) | 24 GiB |
| + ETABS | 32 GiB |
| + Revit (typical project ~200 MB .rvt) | 40 GiB |
| + Revit large model (1+ GB .rvt, cloud workshared) | 48–64 GiB |
| + Rhino.Inside.Revit active + Grasshopper canvas | +2–4 GiB on top |

If Revit joins the daily stack, bump the memory element in
[configs/libvirt/windows-cad.xml](../configs/libvirt/windows-cad.xml)
and the `hugepages=` value in `/boot/limine.conf` together — see doc
02 § 2 for the ladder. Host RAM floor: leave at least 8 GiB for
Omarchy under load, so 48 GiB guest → 56 GiB host minimum.

## Licence considerations

Three common models — all work in the guest:

| Licence | In the guest? | Notes |
|---|---|---|
| **Subscription (Autodesk Account)** | ✅ | Sign in through Autodesk Access on first launch. Activation is tied to your account, not the machine — no reactivation on VM hardware changes. Needs internet from the guest. |
| **Network licence** (Autodesk NLM / LMTOOLS) | ✅ | Point Revit at `port@license-host` in the licence dialog. Guest must route to the licence server — see [doc 13](13-collaboration-and-backup.md) for VPN + corporate-network topology. |
| **Named-user / EBA** | ✅ | Same as subscription — sign in through Autodesk Access. |
| Perpetual (2016 and earlier) | ⚠️ | Autodesk retired perpetual years ago. If you still hold a perpetual key, the activation is machine-ID-locked and may need reactivation after XML edits. |

## Installing Revit

1. Download **Autodesk Access** from your Autodesk Account portal to
   the Omarchy host, drop into `~/src/oma-eng/src/vendor/`, and run
   from `Z:\vendor\` in the guest. (Autodesk Access replaced the old
   Autodesk Desktop App in 2023.)
2. Sign in with your Autodesk Account.
3. From the Access panel, install Revit — pick **Revit 2025** or
   **Revit 2026** to match Rhino.Inside.Revit compatibility (§ below).
4. Reboot the guest after install.
5. Launch Revit at least once so it initialises
   `%APPDATA%\Autodesk\Revit\...`; Rhino.Inside.Revit reads this on
   first load.

Installer size: 5–10 GB, install time 15–30 min. Key paths:

- `C:\Program Files\Autodesk\Revit 2026\` — main install
  (`Revit.exe`, `RevitAPI.dll`, `RevitAPIUI.dll`).
- `%APPDATA%\Autodesk\Revit\Addins\2026\` — user add-ins (where
  Rhino.Inside.Revit and pyRevit register themselves).

## Verify GPU + DirectX

Revit uses DirectX 11. Confirm the passed-through Nvidia dGPU is
doing the work:

1. Inside Revit: *File ▸ Options ▸ Graphics*.
2. **Use hardware acceleration** — ticked.
3. **Video card** should read the Nvidia device.
4. Open the shipped sample (*File ▸ Open ▸ Sample Files ▸
   `rac_advanced_sample_project.rvt`* — the exact filename varies by
   release) and rotate the 3D view. Motion should be smooth at
   monitor refresh.

If the video card reads *Microsoft Basic Render Driver*, the guest is
on the QXL fallback. Same fix as Rhino / ETABS — see
[doc 09 § Rhino uses Microsoft Basic Render Driver](09-troubleshooting.md).

## Installing Rhino.Inside.Revit

McNeel's officially supported Grasshopper-inside-Revit bridge. Free.

**Compatibility (current v1.36.x, as of late 2026):**

- Requires **Rhino 8** for latest features (Rhino 7 covers legacy
  features).
- Revit **2019 through Revit 2026**.
- Rhino must already be installed and licensed — see
  [doc 06](06-rhino-setup.md).

Cross-check the shipped release notes at
<https://www.rhino3d.com/inside/revit/1.0/reference/release-notes>
before installing — McNeel adds Revit support in point releases.

**Install:**

1. Confirm Rhino 8 is installed and licensed (doc 06).
2. Download the current
   `RhinoInside.Revit-1.36-x-x.msi` from
   <https://www.rhino3d.com/inside/revit/>.
3. Run the installer in the guest. It registers the add-in for every
   Revit version present on the machine.
4. Launch Revit. You'll see a *Rhino.Inside* tab in the ribbon.
5. Click the *Start* button in that tab to load Rhino into the Revit
   process.
6. In the loaded Rhino, click *Show Grasshopper* → the Grasshopper
   canvas opens inside Revit.

**Verify:**

- Ribbon shows *Rhino.Inside* tab, and *Grasshopper* / *Python 3* /
  *Compute* buttons.
- Grasshopper's *Revit* tab exposes Element / Category / Family /
  Document components.
- Drop a `Document.CurrentDoc` component onto the canvas — its
  output should show the current Revit project.

**Autoload on Revit start:**

Under *Rhino.Inside ▸ Options*, tick *Load on startup*. This adds
5–10 s to Revit's cold start but avoids the manual click every time.

## Installing pyRevit

Free, GPL v3, open-source Python extension manager for Revit. Widely
used in AEC firms for one-off scripts and shared tool libraries.

**Install:**

1. In the guest, download the current installer from
   <https://github.com/pyrevitlabs/pyRevit/releases/latest>. The
   asset name looks like `pyRevit_6.5.5.<build>_admin_signed.exe`.
2. Run the installer — defaults are fine.
3. Launch Revit. A *pyRevit* tab appears in the ribbon with the
   shipped tools panel.
4. Verify: *pyRevit ▸ About* → shows the installed version and the
   IronPython 2.7 / CPython 3.8+ engine versions.

**Editing scripts from Omarchy:**

Your extensions live under `%APPDATA%\pyRevit-Master\extensions\` in a
specific folder layout
(`.extension\.tab\.panel\.pushbutton\script.py`). Symlink your
extension out to the virtiofs share so you can edit on Omarchy:

```powershell
# In the guest, admin PowerShell:
New-Item -ItemType SymbolicLink `
    -Path "$env:APPDATA\pyRevit-Master\extensions\MyTools.extension" `
    -Target "Z:\src\oma-eng\src\pyrevit-extensions\MyTools.extension"
```

Then edit `script.py` files on Omarchy — pyRevit's *Reload* button
(`Ctrl+F5`) picks up changes without restarting Revit.

**Engine choice:**

- **IronPython 2.7** (default) — full Revit API access, matches most
  existing pyRevit scripts on the web. Stick with this for anything
  you'd share.
- **CPython 3.8+** — via pyRevit's embedded CPython. Faster, supports
  `numpy` / `scipy`, but Revit API access is via `pythonnet` and is a
  hair slower to marshal.

For scripts that touch structural results tables or interoperate with
`numpy`, choose CPython 3. For everything else, IronPython 2.

## API development workflow

For **C# add-ins** (`.addin` + `.dll`):

1. New .NET 8 class library project under `src/revit-api/csharp/`.
   Older Revit (2024 and earlier) targets `net48` — Revit 2025+
   supports `net8.0-windows`.
2. Reference `RevitAPI.dll` and `RevitAPIUI.dll` from
   `C:\Program Files\Autodesk\Revit 2026\` with
   `<Private>false</Private>` (Revit loads them itself; local copies
   cause `TypeLoadException`).
3. Drop an `.addin` manifest at
   `%APPDATA%\Autodesk\Revit\Addins\2026\MyAddin.addin` pointing at
   the built `.dll` path (a symlink to `Z:\...\bin\Debug\` avoids
   copying on every rebuild).
4. Debug via VS Code Remote-SSH → attach to `Revit.exe` — same
   pattern as [doc 06 § 7](06-rhino-setup.md).

For **pyRevit scripts**: edit the `.py` on Omarchy, click *Reload*
(`Ctrl+F5`) in the pyRevit tab, run.

For **Grasshopper inside Revit**: standard `.gh` files. Save under
`~/src/oma-eng/src/rhino-inside-revit/` on Omarchy — they open
transparently inside the Revit-hosted Grasshopper canvas.

## Cross-integration

The interesting workflows are the ones that pass data between Revit
and the rest of the stack:

- **Rhino → Revit** (via Rhino.Inside.Revit + Grasshopper): read
  Rhino Brep geometry, use the *Add Family Instance* / *Add Beam* /
  *Add Column* components to create Revit families. Structural
  columns and beams round-trip cleanly.
- **Revit → ETABS**: CSi ships **CSiXRevit** as a Revit add-in
  (bundled with ETABS 20+). Push the structural analytical model
  from Revit into a new ETABS `.edb`. The round-trip preserves grids,
  storeys, and section assignments.
- **Revit → Strand7**: no first-class link. Export Revit's analytical
  model to IFC 4 (*File ▸ Export ▸ IFC*), then import via Strand7's
  IFC import in R3. Preserves geometry and section assignments;
  loses load cases.
- **Revit → SpaceGass**: use the SPACE GASS REST API (doc 11) — a
  pyRevit script can enumerate `AnalyticalNode` / `AnalyticalMember`
  collections, marshal to JSON, and
  `POST /api/v1/job/structure/nodes/bulk`. See
  [src/spacegass-api/](../src/spacegass-api/) for the REST client
  shape.
- **Revit → Excel**: same late-bound COM pattern as
  [src/office-integration/csharp/RhinoToExcel/](../src/office-integration/csharp/RhinoToExcel/).
  Dump schedules, quantity takeoffs, or family-parameter tables.

## Snapshot

```bash
virsh --connect qemu:///system snapshot-create-as windows-cad revit-installed \
    "Revit + Rhino.Inside.Revit + pyRevit installed and verified"
```

## Exit criteria

- Revit → *File ▸ Options ▸ Graphics* reports the Nvidia GPU.
- The shipped sample project opens and rotates smoothly at monitor
  refresh.
- Rhino.Inside.Revit's *Rhino.Inside* tab loads without warnings;
  clicking *Start* opens Rhino inside the Revit process and
  *Grasshopper* opens a canvas.
- pyRevit tab loads; *pyRevit ▸ About* shows the installed version
  and both engines.
- Optional: if you plan to use the Revit API, a class-library project
  referencing `RevitAPI.dll` + `RevitAPIUI.dll` builds and VS Code
  Remote-SSH attaches to `Revit.exe`.

Continue to [13 — Bluebeam Revu + collaboration workflows](13-collaboration-and-backup.md).
