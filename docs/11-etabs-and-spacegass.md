# 11 — CSi ETABS + SpaceGass

Both are Windows-native structural analysis packages. Neither runs
under Wine reliably. Both install into the existing VFIO CAD guest
without changes to the passthrough architecture — but each brings
its own licence, RAM footprint, and automation surface. This page
covers all of that in one place.

Read after [10 — Office / Excel integration](10-office-integration.md).

## Where they live

**In the same VFIO guest as Rhino + Strand7 + Excel** — with one
caveat noted below for SpaceGass. Reasons are the same as for Excel:

- Multi-app COM/OAPI interop needs everything in one Windows session
  (ETABS OAPI → Excel via `Interop.Excel`, Strand7 → Excel via
  `xlwings`, and so on).
- The Nvidia dGPU is already there; ETABS and SpaceGass both use
  OpenGL for their model view and benefit from real GPU acceleration
  with big frames.
- One licensed Windows install to manage.

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
| + ETABS (typical building models) | 32 GiB |
| + ETABS (200+ storey model, non-linear time-history) | 48 GiB |
| + SpaceGass (typical) | +2–4 GiB on top |
| + big Excel dashboards driven by OAPI | +4–8 GiB |

If you routinely open ETABS with the rest of the stack, bump the
default in [configs/libvirt/windows-cad.xml](../configs/libvirt/windows-cad.xml)
to 32 GiB (`33554432` KiB) and remember to also bump `hugepages=` in
`/boot/limine.conf` and either
[configs/sysctl.d/99-vm-hugepages.conf](../configs/sysctl.d/99-vm-hugepages.conf)
or [configs/systemd/hugepages.service](../configs/systemd/hugepages.service)
to match.

Watch host RAM: leave at least **8 GiB for Omarchy** even under heavy
guest load, or your Wayland session starts stuttering. So 32 GiB guest
→ 40 GiB host RAM minimum.

## Licences and dongles

Both vendors historically use **SentinelHASP** (formerly Aladdin) USB
dongles. Both also offer network / cloud licence servers, and cloud
options have grown in the last few years.

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
- **SpaceGass** — *Help ▸ Registration* → network licence entry.

### CSiCloud / cloud licences

CSi has been pushing CSiCloud for new users. Works fine in the VM:
sign in through the app once, then it just runs. No dongle
passthrough needed.

## Installing ETABS

1. Download the ETABS installer from CSi's client portal to the
   Omarchy host, drop into `~/src/rhino-omarchy/src/vendor/`, and
   it appears at `Z:\vendor\` in the guest via virtiofs.
2. Run the installer in the guest. Accept defaults.
3. Install the Sentinel HASP runtime if not already present.
4. Launch ETABS. Licence dialog picks up the dongle or lets you enter
   the network server.
5. *Options ▸ Preferences ▸ Dimensions/Tolerances ▸ Display Options*
   → enable OpenGL acceleration if not already on.
6. Quick smoke test: *File ▸ New Model* → pick any grid → run the
   built-in analysis. Should complete in seconds. Confirm the model
   view rotates smoothly.

### Verify GPU usage

The `_SystemInfo`-equivalent in ETABS is *Help ▸ System Info*. It
reports the OpenGL device — should read the Nvidia card.

If it reports *GDI Generic* or *Microsoft Basic Render Driver*, the
QXL fallback adapter is still driving ETABS. Fix per doc 09
(*Rhino uses Microsoft Basic Render Driver*) — the same steps apply.

## Installing SpaceGass

Use **SPACE GASS 14.5 or later** — earlier releases don't ship the
REST API that the samples in this repo target.

1. Download from the licensed-users page on spacegass.com to the host,
   drop into `~/src/rhino-omarchy/src/vendor/`, run from `Z:\vendor\`.
2. If your licence is dongle-based, install the dongle runtime (Sentinel
   HASP or CodeMeter/WIBU depending on your dongle vintage — the
   installer usually prompts).
3. Launch SPACE GASS at least once. This initialises the data files
   the API service depends on.
4. Verify graphics: *Settings ▸ Preferences ▸ Display*. Renderer should
   read the Nvidia card.
5. Start the API service (optional, only if you plan to use the API —
   the GUI does not need it):
   - Double-click the **SPACE GASS API** shortcut under the SPACE GASS
     Windows application folder, or
   - `"C:\Program Files\SPACE GASS 14.5\SpaceGassApi.exe"` from an
     admin PowerShell.
   The service listens on `http://localhost:34560`. Browse
   `http://localhost:34560/swagger` for the interactive endpoint
   catalogue.

## API landscape

### ETABS — OAPI

ETABS ships a well-documented **OAPI (Open API)** as
`ETABSv1.dll` under `C:\Program Files\Computers and Structures\ETABS
22\`. Same design as CSi's SAP2000 OAPI, so if you've automated one
you've automated the other. The vendor's own C# / VBA / Python
samples ship under `C:\Program Files\Computers and Structures\ETABS
22\API\` — clone one of those as a starting point.

**Interop namespace when you reference `ETABSv1.dll` directly:**
`CSiAPIv1` (shared with SAP2000). Interfaces `cHelper`, `cOAPI`,
`cSapModel`; instantiate the concrete class `Helper` to bootstrap.

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
using CSiAPIv1;                         // when referencing the DLL

// cHelper is an interface; Helper is the concrete class.
cHelper helper = new Helper();
cOAPI etabs = helper.CreateObjectProgID("CSI.ETABS.API.ETABSObject")
    ?? throw new InvalidOperationException("ETABS COM object not found.");
etabs.ApplicationStart();
cSapModel model = etabs.SapModel;
model.InitializeNewModel(eUnits.kip_in_F);   // eUnits.kip_in_F = 3
model.File.NewBlank();
// ... build model, save, run analysis, extract results ...
model.File.Save(@"C:\Users\Public\demo.edb");   // required before RunAnalysis
model.Analyze.RunAnalysis();
```

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
- **Rhino → ETABS** — a Grasshopper component reads a topology from
  Rhino geometry, calls `SapModel.PointObj.AddCartesian`, etc.
  This is essentially what commercial plugins like *Karamba3D-to-CSi*
  or *Rhino Inside ETABS* do. You can build a lightweight in-house
  version in the same repo.
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

- Both ETABS and SPACE GASS installed and licensed inside the guest.
- Both report the Nvidia GPU in their graphics preferences panels.
- ETABS `SystemInfo` shows OpenGL renderer = Nvidia card.
- A test analysis in each completes with expected wall times (linear
  static on a small frame: sub-second).
- If you plan to use API automation: `ETABSv1.dll` is reachable and
  CSi's licence server / dongle answers when the API starts a session
  (this consumes a licence just like the GUI does); and
  `curl http://localhost:34560/api/v1/service/info` from an admin
  PowerShell in the guest returns a 200 response with a SPACE GASS
  version string.

Back to [README](../README.md).
