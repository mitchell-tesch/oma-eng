# 11 — CSi ETABS + SAP2000 + SpaceGass

All three are Windows-native structural analysis packages. None run
under Wine reliably. All install into the existing VFIO CAD guest
without changes to the passthrough architecture — but each brings
its own licence, RAM footprint, and automation surface. This page
covers all three in one place because ETABS and SAP2000 share the
same CSi OAPI (any automation you write for one nearly ports to the
other with a ProgID swap), and SPACE GASS shares the CSi cross-platform
constraint set even though its API is REST rather than COM.

Read after [10 — Office / Excel integration](10-office-integration.md).

## Where they live

**In the same VFIO guest as Rhino + Strand7 + Excel** — with one
caveat noted below for SpaceGass. Reasons are the same as for Excel:

- Multi-app COM/OAPI interop needs everything in one Windows session
  (ETABS OAPI → Excel via `Interop.Excel`, Strand7 → Excel via
  `xlwings`, and so on).
- The Nvidia dGPU is already there; ETABS, SAP2000, and SpaceGass
  all use OpenGL for their model view and benefit from real GPU
  acceleration with big frames.
- One licensed Windows install to manage.
- ETABS and SAP2000 share the CSi runtime (`CSiAPIv1.dll`) and,
  if you're on a network licence, the same Reprise licence pool —
  installing both alongside each other is the intended CSi
  deployment.

**SpaceGass 14.5+ is the exception.** Its automation surface is a
local REST HTTP service (`SpaceGassApi.exe`), not COM, so the
automation client doesn't need to share a Windows session with
SpaceGass — you can drive it from Omarchy over the guest's virtio-net
interface. The GUI still needs to run in the guest for the OpenGL
view, but Python/C# clients targeting the SpaceGass API can live
anywhere that can reach port 34560. See
[src/spacegass-api/README.md](../src/spacegass-api/README.md) for the
port-forward / cross-network options.

## RAM sizing ladder

With the full engineering stack open concurrently:

| Apps you routinely run at once | Guest RAM |
|---|---|
| Rhino only | 16 GiB |
| Rhino + Strand7 + Excel (repo default) | 24 GiB |
| + ETABS **or** SAP2000 (typical building models) | 32 GiB |
| + ETABS + SAP2000 concurrently | 36 GiB |
| + ETABS (200+ storey model, non-linear time-history) | 48 GiB |
| + SpaceGass (typical) | +2–4 GiB on top |
| + big Excel dashboards driven by OAPI | +4–8 GiB |

If you routinely open ETABS or SAP2000 with the rest of the stack,
retarget the guest to 32 GiB with the helper — it edits
[configs/libvirt/windows-cad.xml](../configs/libvirt/windows-cad.xml),
[configs/sysctl.d/99-vm-hugepages.conf](../configs/sysctl.d/99-vm-hugepages.conf),
and
[configs/systemd/hugepages.service](../configs/systemd/hugepages.service)
atomically, then prints the exact `hugepages=` value to paste onto
the Limine cmdline:

```bash
scripts/set-guest-memory 32               # or 40, 48 as needed
```

Watch host RAM: leave at least **8 GiB for Omarchy** even under heavy
guest load, or your Wayland session starts stuttering. So 32 GiB guest
→ 40 GiB host RAM minimum.

## Licences and dongles

CSi and StruSoft support several licence models, all of which work in
this VM. In order of "just works":

### CSiCloud / cloud licences (recommended in a VM)

CSi has been pushing CSiCloud for new users. Same shape as Strand7's
CLM (doc 07 §1): sign in through ETABS or SAP2000's licence dialog
with your CSi account, tick *Remember me*, done. Snapshot reverts
don't invalidate anything — the entitlement lives on CSi's side, not
tied to a local machine ID.

The libvirt default NAT gives the guest outbound HTTPS to CSi's cloud
endpoint. If you followed [doc 02 §10](02-host-setup.md), UFW is
already whitelisting `virbr0`; nothing extra to open.

CSi's OAPI shares the licence pool with the GUI — running
`dotnet run` against `HelloETABS.exe` (§ C# OAPI smoke test below)
checks out a token the same way `ETABS.exe` does. Launch ETABS once
to sign in, close it, and the API calls then work without further
prompts.

### Physical dongles — pass through with libvirt

Enumerate on the Omarchy host:

```bash
lsusb | grep -Ei 'sentinel|hasp|aladdin|marx|codemeter|wibu'
```

You'll typically see something like:

```
Bus 001 Device 007: ID 0529:0001 SafeNet Sentinel HASP key
```

Add a `<hostdev>` block per dongle to
[configs/libvirt/windows-cad.xml](../configs/libvirt/windows-cad.xml)
(the template already has one commented out for Strand7 — add extras
for CSi and SpaceGass):

```xml
<!-- Strand7 HASP -->
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor  id='0x0529'/>
    <product id='0x0001'/>
  </source>
</hostdev>

<!-- CSi (ETABS) SentinelHASP -->
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor  id='0x0529'/>
    <product id='0x000b'/>   <!-- EDIT: your actual product id -->
  </source>
</hostdev>

<!-- SpaceGass HASP or CmStick — EDIT: SPACE GASS's dongle vendor
     differs by installation vintage; check `lsusb` output above and
     substitute both IDs. Recent installs are increasingly cloud-
     licensed (see § Cloud / subscription licences below), in which
     case no dongle passthrough is needed. -->
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor  id='0xXXXX'/>
    <product id='0xYYYY'/>
  </source>
</hostdev>
```

Multiple concurrent dongles work fine — QEMU passes each through as an
independent USB device. You'll also want to install the vendor
runtimes in the guest:

- **Sentinel HASP Runtime** — covers both Strand7 and CSi. Get it from
  [Thales/Sentinel downloads](https://cpl.thalesgroup.com/software-monetization/sentinel-drivers).
  Install once; both apps then see their dongles.
- **CodeMeter Runtime (WIBU)** — SpaceGass may use CmStick depending on
  vintage. Get it from wibu.com if needed.

### Network licence servers

If your firm runs `RMS` (CSi's Reprise Licence Manager), `hasplm`
(Sentinel), or a StruSoft licence server, just make sure the guest can
reach the server on the LAN (`ping licence-server.example.local` from
an admin PowerShell in the guest). No dongle passthrough needed.

Point each app at the server via its usual licence configuration:

- **ETABS** — first-launch dialog offers a licence server; enter the
  Reprise server address (`5054@license-host` style).
- **SAP2000** — same first-launch dialog and same Reprise server;
  the pool is shared, so a firm licence covers both if both features
  are on the licence.
- **SpaceGass** — *Help ▸ Registration* → network licence entry.

### CSiCloud / cloud licences

See the top of this section — the recommended VM path is CSiCloud,
covered there.

## Installing ETABS

1. Download the ETABS installer from CSi's client portal to the
   Omarchy host, drop into `~/dev/oma-eng/src/vendor/`, and
   it appears at `Z:\vendor\` in the guest via virtiofs.
2. Run the installer in the guest. Accept defaults. This repo's
   default is ETABS 23 (`C:\Program Files\Computers and Structures\
   ETABS 23\`); other versions (22, 24, …) install alongside without
   conflict and share the same OAPI shape.
3. Install the Sentinel HASP runtime only if your licence is
   dongle-based. Skip for CSiCloud or Reprise (network) licences.
4. Launch ETABS. Depending on licence model:
   - **CSiCloud**: sign in with your CSi account; token cached for
     future sessions and API calls.
   - **HASP dongle**: picked up automatically once passed through.
   - **Network licence**: enter the Reprise address
     (`5054@license-host`) in the first-run licence dialog.
5. *Options ▸ Preferences ▸ Dimensions/Tolerances ▸ Display Options*
   → enable OpenGL acceleration if not already on.
6. Quick smoke test: *File ▸ New Model* → pick any grid → run the
   built-in analysis. Should complete in seconds. Confirm the model
   view rotates smoothly.

### Verify GPU usage

Same pattern as doc 07 §3 for Strand7. With ETABS open on a model,
in an admin PowerShell inside the guest:

```powershell
nvidia-smi
```

The *Processes* block should list `ETABS.exe`. GPU memory shows
`N/A` under WDDM — expected, see [doc 09 § `nvidia-smi` shows
`N/A`](09-troubleshooting.md). ETABS *Help ▸ System Info* also
reports the OpenGL device but is less reliable on muxless-VDD
setups; `nvidia-smi` is ground truth.

If `ETABS.exe` isn't in the list, ETABS is on the QXL / Microsoft
Basic Render Driver fallback. Fix per doc 09 (*Rhino uses Microsoft
Basic Render Driver*) — the same steps apply.

## Installing SAP2000

CSi's general-purpose FEA package. Same installer flow as ETABS,
same Reprise licence pool, same OAPI shape — with a ProgID swap.

1. Download the SAP2000 installer from CSi's client portal to the
   Omarchy host, drop into `~/dev/oma-eng/src/vendor/`, and run from
   `Z:\vendor\` in the guest.
2. Accept defaults. Install location is
   `C:\Program Files\Computers and Structures\SAP2000 26\`
   (folder name follows the point release — `SAP2000 25\` for v25,
   etc.).
3. The Sentinel HASP runtime installed for ETABS covers SAP2000 too;
   no second install is needed. Same story for the Reprise (RLM)
   licence server — SAP2000 authenticates against the same
   `port@licence-host` you configured for ETABS.
4. Launch SAP2000. Licence dialog either picks up the dongle / RLM
   pool or lets you enter the network server.
5. *Options ▸ Preferences ▸ Graphics* → confirm **DirectX** or
   **OpenGL** with hardware acceleration on. SAP2000 defaults to
   DirectX on modern Windows 11; either works with the
   passed-through Nvidia dGPU.
6. Quick smoke test: *File ▸ New Model* → *Blank* → add two joints,
   a frame, run linear-static. Should complete in seconds.

### Verify GPU usage — SAP2000

Same `nvidia-smi` check as ETABS: with SAP2000 open on a model,
`SAP2000.exe` should show up in the *Processes* block (memory `N/A`
under WDDM). *Help ▸ About SAP2000* reports the OpenGL / DirectX
renderer as a secondary check.

## Installing SpaceGass

Use **SPACE GASS 14.5 or later** — earlier releases don't ship the
REST API that the samples in this repo target.

1. Download from the licensed-users page on spacegass.com to the host,
   drop into `~/dev/oma-eng/src/vendor/`, run from `Z:\vendor\`.
2. Licence model:
   - **Cloud / subscription** — sign in through SPACE GASS's licence
     dialog with your StruSoft account. Snapshot-revert-safe like
     CSiCloud and Strand7 CLM. Uses the guest's default NAT for
     outbound HTTPS; no dongle setup or LAN server needed.
   - **HASP dongle / CmStick (WIBU)** — install the matching runtime
     when the installer prompts; pass the dongle through with the
     `<hostdev>` block from §Physical dongles above.
   - **StruSoft network licence** — enter server address at first
     launch.
3. Launch SPACE GASS at least once. This initialises the data files
   the API service depends on.

### Verify GPU usage — SpaceGass

Same `nvidia-smi` check as ETABS/SAP2000: with SPACE GASS open on a
model, `SpaceGass.exe` should appear in the *Processes* block (memory
`N/A` under WDDM). *Settings ▸ Preferences ▸ Display* also reports
the OpenGL renderer as a secondary check.

### Start the API service

Only needed if you plan to use the REST API — the GUI works
standalone. Discover the install path (version-agnostic):

```powershell
Get-ChildItem "C:\Program Files\SPACE GASS *" -Directory |
    Select-Object -ExpandProperty FullName
# e.g. C:\Program Files\SPACE GASS 14.5
#   or C:\Program Files\SPACE GASS 15.0
```

Then launch the API service:

- Double-click the **SPACE GASS API** Start-menu shortcut, or
- `Start-Process "$installPath\SpaceGassApi.exe"` from an admin
  PowerShell, substituting the path from `Get-ChildItem`.

The service listens on `http://localhost:34560`. Windows Firewall
prompts on first launch — allow *Private networks* (leave *Public*
off). Browse `http://localhost:34560/swagger` for the interactive
endpoint catalogue.

## REST API smoke test — SpaceGass

With the API service running (see §Installing SpaceGass ▸ Start the
API service), from an admin PowerShell in the guest:

```powershell
Invoke-RestMethod http://localhost:34560/api/v1/service/info
```

Expected: a small JSON object with fields like `version`,
`apiVersion`, `serviceStatus`. A 200 response with a SpaceGass
version string in the body is a pass — the whole HTTP-plus-service
chain is working end-to-end.

For a fuller smoke test (opens a shipped sample, runs linear-static,
prints reactions), see the repo samples:

- Python: [`src/spacegass-api/python/hello_spacegass.py`](../src/spacegass-api/python/hello_spacegass.py)
- C#: [`src/spacegass-api/csharp/HelloSpaceGass/`](../src/spacegass-api/csharp/HelloSpaceGass/)

Both use the vendor-generated `space-gass-api` / `SpaceGassApi` client
packages (Microsoft Kiota under the hood). See
[`src/spacegass-api/README.md`](../src/spacegass-api/README.md) for
port-forward notes if you want to drive the API from Omarchy over the
guest's virtio-net interface rather than from inside the guest.

## C# OAPI smoke test — ETABS

Repo sample:
[`src/etabs-api/csharp/HelloETABS/`](../src/etabs-api/csharp/HelloETABS/).
Late-bound COM class factories fail on modern ETABS (see §API
landscape below and doc 09), so the sample uses CSi's `Helper` +
`CreateObjectProgID` pattern with strong `cOAPI` / `cSapModel` types
from `ETABSv1.dll`. It builds a two-node cantilever column, applies
a 10 kip horizontal load, runs linear-static, and prints the base
reaction.

From an interactive PowerShell in the guest (Looking Glass or VS Code
Remote-SSH terminal — not plain `ssh windows-cad`):

```powershell
cd Z:\etabs-api\csharp\HelloETABS
dotnet build -c Release
dotnet run -c Release
```

The csproj references `ETABSv1.dll` from `$(ETABSInstallDir)`,
defaulting to ETABS 23. Override for other versions:

```powershell
dotnet build -c Release -p:ETABSInstallDir="C:\Program Files\Computers and Structures\ETABS 22"
```

Expected output ending with:

```
Reaction @ '1' case 'HELLO_DEAD': Fx=-10 Fy=0 Fz=0  Mx=0 My=1440 Mz=0
Hello from ETABS on Omarchy.
```

Fx = −10 kip (equal-and-opposite to the applied load) and My = 1440
kip·in (10 kip × 144 in column) confirm the whole pipeline is wired
correctly. ETABS launches visibly, runs the analysis, then exits.

**F5 debug from VS Code** — the sample ships
[`.vscode/launch.json`](../src/etabs-api/csharp/HelloETABS/.vscode/launch.json),
[`tasks.json`](../src/etabs-api/csharp/HelloETABS/.vscode/tasks.json),
and [`extensions.json`](../src/etabs-api/csharp/HelloETABS/.vscode/extensions.json).
Remote-SSH into the guest, open `Z:\etabs-api\csharp\HelloETABS`,
accept the Dev Kit recommendation, wait for solution restore, F5.
Same as HelloStrand7 / HelloRhino — see [doc 07 §8](07-strand7-setup.md)
for the flow.

### Porting to SAP2000

Three changes to `HelloETABS/Program.cs`:

```csharp
// Before (ETABS):                        // After (SAP2000):
using ETABSv1;                            using SAP2000v1;
"CSI.ETABS.API.ETABSObject"               "CSI.SAP2000.API.SapObject"
@"...\HelloETABS_scratch.edb"             @"...\HelloSAP2000_scratch.sdb"
```

And the csproj `ETABSInstallDir` becomes `SAPInstallDir` pointing at
your `SAP2000 26\` (or later) install with a `<Reference>` to
`SAP2000v1.dll`. Everything else — `PointObj.AddCartesian`,
`FrameObj.AddByPoint`, `Analyze.RunAnalysis`, `Results.JointReact` —
compiles unchanged.

## API landscape

### ETABS — OAPI

ETABS ships a well-documented **OAPI (Open API)** as
`ETABSv1.dll` under `C:\Program Files\Computers and Structures\ETABS
22\`. Same design as CSi's SAP2000 OAPI, so if you've automated one
you've automated the other. The vendor's own C# / VBA / Python
samples ship under `C:\Program Files\Computers and Structures\ETABS
22\API\` — clone one of those as a starting point.

**Interop namespace when you reference `ETABSv1.dll` directly:**
`ETABSv1` (per-app; SAP2000 uses `SAP2000v1`, which is confusingly
not the same as the older CSi convention). Interfaces `cHelper`,
`cOAPI`, `cSapModel`; instantiate the concrete class `Helper` to
bootstrap. Note: `Helper`'s methods are explicit `cHelper`
implementations, so the local must be typed as `cHelper` (not `var`
or `Helper`) to access `CreateObjectProgID`. Same rule applies to
every method on `cOAPI` / `cSapModel` — use the interface types, not
the co-classes, and don't try to drive them through `dynamic`
(the runtime binder can't see explicit interface members).

**Object model root:**
`cOAPI` (app object) → `SapModel` (main model interface) → sub-interfaces
(`PointObj`, `FrameObj`, `AreaObj`, `PropMaterial`, `PropFrame`,
`LoadPatterns`, `LoadCases`, `Analyze`, `Results`, …).

**Calling from:**

- **C# / .NET** — reference `ETABSv1.dll` directly (or use late-bound
  COM). Preferred for real plugins.
- **Python** — via `comtypes.client.CreateObject("ETABSv1.Helper")` +
  `helper.CreateObjectProgID("CSI.ETABS.API.ETABSObject")`. Standard
  `pywin32 Dispatch` also works. The community `etabs-api` pip
  package wraps this.
- **VB.NET / VBA** — same COM path as Python.
- **MATLAB** — via the .NET assembly reference.

**Typical pattern:**

```csharp
using ETABSv1;                          // when referencing the DLL

// cHelper is an interface; Helper is the concrete class.
cHelper helper = new Helper();
cOAPI etabs = helper.CreateObjectProgID("CSI.ETABS.API.ETABSObject")
    ?? throw new InvalidOperationException("ETABS COM object not found.");
etabs.ApplicationStart();                     // parameterless since v16.1
cSapModel model = etabs.SapModel;
model.InitializeNewModel(eUnits.kip_in_F);   // eUnits.kip_in_F = 3
model.File.NewBlank();
// ... build model, save, run analysis, extract results ...
model.File.Save(@"C:\Users\Public\demo.edb");   // required before RunAnalysis
model.Analyze.RunAnalysis();
```

### SAP2000 — OAPI (shares the CSi surface)

SAP2000 exposes the **same OAPI shape** as ETABS. Once you have a
`cSapModel` handle, the code that drives ETABS drives SAP2000 too.
Three concrete differences:

| | ETABS | SAP2000 |
|---|---|---|
| **Interop DLL** | `ETABSv1.dll` | `SAP2000v1.dll` |
| **ProgID** (late-bound COM) | `CSI.ETABS.API.ETABSObject` | `CSI.SAP2000.API.SapObject` |
| **Interop namespace** | `ETABSv1` | `SAP2000v1` |
| **Install path** | `C:\Program Files\Computers and Structures\ETABS 23\` | `C:\Program Files\Computers and Structures\SAP2000 26\` |
| **Model file extension** | `.edb` | `.sdb` |

Any code targeting `cSapModel` sub-interfaces (`PointObj`,
`FrameObj`, `AreaObj`, `LoadPatterns`, `Analyze`, `Results`, …)
is portable across both apps. Vendor sample projects live under the
respective install's `API\` subfolder.

**Porting the [HelloETABS](../src/etabs-api/csharp/HelloETABS/) sample
to SAP2000:** the changes are three lines:

```csharp
// Before (ETABS):
private const string ProgID = "CSI.ETABS.API.ETABSObject";
// ...
Check(sap.File.Save(@"C:\Users\Public\HelloETABS_scratch.edb"),
      "File.Save");

// After (SAP2000):
private const string ProgID = "CSI.SAP2000.API.SapObject";
// ...
Check(sap.File.Save(@"C:\Users\Public\HelloSAP2000_scratch.sdb"),
      "File.Save");
```

Everything else — `PointObj.AddCartesian`, `FrameObj.AddByPoint`,
`Analyze.RunAnalysis`, `Results.JointReact` — is unchanged.
`eUnits.kip_in_F` (value `3`) means the same in both.

**Calling from other languages:** same story as ETABS —
`comtypes.client.CreateObject("SAP2000v1.Helper")` +
`CreateObjectProgID("CSI.SAP2000.API.SapObject")` from Python;
`Dispatch("SAP2000.SapObject")` from VBA. See the ETABS subsection
above for the pattern.

### SpaceGass — REST HTTP API (14.5+)

SPACE GASS 14.5 introduced an official **REST HTTP API** served by
`SpaceGassApi.exe` — a headless local service on `http://localhost:34560`
by default, with a full OpenAPI 3 surface and Swagger UI. There is
**no COM interface** to `SpaceGass.Application`, no `.sg2` batch CLI,
and no printout-scraping. Vendor docs live at
<https://api.spacegass.com/docs/overview>.

**Endpoints of interest:**
- `POST /api/v1/job/open` / `open-sample` / `close` — job lifecycle.
- `GET  /api/v1/job/structure/nodes` / `members` / `sections` /
  `materials` — structural data.
- `POST /api/v1/job/analysis/static/run-linear` (also `run-non-linear`,
  `run-buckling`, `run-dynamic-frequency`) — start a run.
- `GET  /api/v1/job/analysis/runs/{runId}` — poll progress.
- `GET  /api/v1/job/query/analysis/static/node-reactions` /
  `node-displacements` / `member-forces` — read results.

Browse the full surface at `http://localhost:34560/swagger` while the
service is running.

**Calling from:**

- **Python** — install `space-gass-api` (pip). Async SDK generated
  from the OpenAPI spec via Microsoft Kiota. Sample:
  [`src/spacegass-api/python/hello_spacegass.py`](../src/spacegass-api/python/hello_spacegass.py).
- **C# / .NET** — install `SpaceGassApi` (NuGet). Same generator. Sample:
  [`src/spacegass-api/csharp/HelloSpaceGass/`](../src/spacegass-api/csharp/HelloSpaceGass/).
- **Any HTTP client** — `curl`, `httpx`, `HttpClient`, Postman,
  Insomnia. Machine-readable OpenAPI spec at
  <https://api.spacegass.com/docs/api/1/schema.json>.

**Typical pattern (Python):**

```python
from space_gass_api import SpaceGassApiClient
import space_gass_api.models as models

client = SpaceGassApiClient.create_client("http://localhost:34560")
await client.job.open_sample.post(
    models.OpenSampleRequest(file_name="Portal Frame.SG"))
run = await client.job.analysis.static.run_linear.post(
    models.StaticSettingsUpdate())
# poll client.job.analysis.runs.by_run_id(run.run_id).get() until Completed
reactions = await client.job.query.analysis.static.node_reactions.get()
await client.job.close.post()
```

**Cross-network use:** because the API is plain HTTP with no
authentication, clients don't need to share a Windows session with the
service — you can drive it from Omarchy over the guest's virtio-net
interface (`http://<guest-ip>:34560` after allowing the port through
Windows Firewall) or through an SSH tunnel (`ssh -L 34560:localhost:34560
windows-cad`). See [src/spacegass-api/README.md](../src/spacegass-api/README.md).

**Structural Toolkit** — SPACE GASS acquired Structural Toolkit in
2024. If you use both, check *Help ▸ Integrations* inside SPACE GASS
for documented data hand-offs. Out of scope for this repo.

## Cross-integration

The interesting workflows aren't running each package in isolation —
they're passing data between them. Because everything lives in the
same VFIO guest with the same virtiofs-mounted `src/` tree, this is
easy:

- **ETABS → Excel** — extend the pattern in
  [`src/office-integration/csharp/RhinoToExcel/`](../src/office-integration/csharp/RhinoToExcel/):
  same late-bound Excel COM approach, iterate `SapModel.Results.*` for
  storey drifts / member forces, bulk-write to `Range.Value`.
- **SAP2000 → Excel** — identical code path, `SAP2000v1.dll` +
  `CSI.SAP2000.API.SapObject` in place of the ETABS ProgID. Same
  `Results.*` interfaces.
- **Rhino → ETABS / SAP2000** — a Grasshopper component reads a
  topology from Rhino geometry, calls
  `SapModel.PointObj.AddCartesian`, etc. This is essentially what
  commercial plugins like *Karamba3D-to-CSi* or *Rhino Inside ETABS*
  do. You can build a lightweight in-house version in the same repo.
- **ETABS ↔ SAP2000** — either can export the other's model via
  *File ▸ Export* → CSi text file, and re-import. Preserves geometry
  and section assignments across the two solvers.
- **Strand7 ↔ ETABS** — no first-class interchange; export
  Strand7 nodes/elements to a text intermediate and generate a `.$ET`
  from a Python bridge. Slow but reliable.
- **SpaceGass → Excel** — with the REST API you can query results
  directly and push tables through `xlwings`. The Strand7 sample
  [`src/office-integration/python/strand7_to_excel.py`](../src/office-integration/python/strand7_to_excel.py)
  demonstrates the Excel-writing half; replace the ctypes calls with
  `space-gass-api` calls (see
  [`src/spacegass-api/python/hello_spacegass_analysis.py`](../src/spacegass-api/python/hello_spacegass_analysis.py))
  and you have SpaceGass → Excel.
- **Rhino → SpaceGass** — the REST API takes JSON payloads for
  bulk-adding nodes and members
  (`POST /api/v1/job/structure/nodes/bulk`, `.../members/bulk`), so a
  Grasshopper component can produce the topology on the Omarchy side
  and post it directly to the guest's API service — no in-guest
  Python required. See [src/spacegass-api/README.md](../src/spacegass-api/README.md)
  for the port-forward notes.

## Exit criteria

- ETABS, SAP2000 (if installed), and SPACE GASS installed and
  licensed inside the guest.
- `nvidia-smi` in an admin PowerShell in the guest lists `ETABS.exe`
  (and `SAP2000.exe`, `SpaceGass.exe` if you also have those
  running) under *Processes* while each app is on a model. Memory
  shows `N/A` under WDDM — expected, see doc 09.
- A test analysis in each completes with expected wall times (linear
  static on a small frame: sub-second).
- If you plan to use API automation:
  [`src/etabs-api/csharp/HelloETABS`](../src/etabs-api/csharp/HelloETABS/)
  builds and `dotnet run -c Release` prints the base-reaction line
  ending in `Hello from ETABS on Omarchy.` (see § C# OAPI smoke
  test above); and `curl http://localhost:34560/api/v1/service/info`
  from an admin PowerShell in the guest returns a 200 response with
  a SPACE GASS version string.

Continue to [12 — Revit + Rhino.Inside.Revit + pyRevit](12-revit-and-rhino-inside.md).
