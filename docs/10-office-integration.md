# 10 — Office / Excel integration

Once the VFIO CAD guest is running, you'll almost certainly want Excel
alongside Rhino and Strand7. Engineering workflows depend on it —
model input tables, load matrices, post-processing summaries, and
the countless bits of automation that walk from a spreadsheet into a
solver and back.

This page decides *where* Excel lives, sizes RAM accordingly, and
covers the licence + activation quirks specific to running Office in
a VM. It's the last doc in the setup path because it depends on
choices made earlier — you have to know how much RAM your guest is
already using before you can size for Office.

## Where to put Excel

Three viable options:

### A. Same VFIO CAD VM (recommended default)

Install Excel (or the whole Microsoft 365 / Office 2021 bundle) inside
the same Windows 11 guest that runs Rhino and Strand7. Nothing about
the VM changes; Office is just another Windows app.

**When to pick this:**
- Any of your Rhino/Grasshopper/Strand7 scripts drive Excel via COM
  (`Microsoft.Office.Interop.Excel`, `xlwings`, `pywin32
  Dispatch("Excel.Application")`). COM is per-Windows-session — the
  caller and Excel must share the same OS instance.
- You want Excel to render on the passed-through Nvidia GPU (helps
  with heavy dashboards, conditional formatting, big charts).
- You want a single seamless Looking Glass window for all your
  Windows work.

**Cost:** RAM. Bump the guest to 24 GiB (this repo's default) or
32 GiB if you routinely open large workbooks. Use
[`scripts/set-guest-memory <GiB>`](../scripts/set-guest-memory) to
retarget [`configs/libvirt/windows-eng.xml`](../configs/libvirt/windows-eng.xml),
[`configs/sysctl.d/99-vm-hugepages.conf`](../configs/sysctl.d/99-vm-hugepages.conf),
and [`configs/systemd/hugepages.service`](../configs/systemd/hugepages.service)
atomically; the script also prints the `hugepages=N` snippet to
paste onto the Limine cmdline.

### B. Omarchy's built-in `omarchy windows vm` (Dockur)

Run Excel in the separate lightweight Windows VM Omarchy ships out of
the box (*Install ▸ Windows* in the Omarchy menu, or
`omarchy windows vm launch`).

**When to pick this:**
- You want a quick Office window that's available even when the CAD
  VM is off.
- You don't need COM automation between Excel and Rhino/Strand7.
- You want Omarchy's clipboard/RDP integration to Just Work with no
  extra config.

**Cost:** A second Windows VM to licence, update, and populate. No GPU
passthrough — fine for spreadsheets but limits chart rendering.

You can absolutely run **both**: the built-in VM for casual Office
sessions all day, the VFIO CAD VM only when you sit down to design.
They're independent.

### C. LibreOffice Calc or Excel for the Web

Native Omarchy install (`sudo pacman -S libreoffice-fresh`) or open
<https://www.office.com> in a browser.

**When to pick this:**
- Quick `.xlsx` viewing, casual edits, no VBA or COM.
- You want zero Windows dependency in your Omarchy session.

**Cost:** VBA macros don't run. Complex conditional formatting can
render differently. Power Query works on the web version but not in
LibreOffice.

Most engineering shops end up with **A + C** — Excel in the CAD VM
for real work, LibreOffice on Omarchy for opening drop-in
attachments.

## Installing Office in the VFIO guest

Nothing special. From an admin PowerShell in the guest:

**Microsoft 365 (recommended, subscription):**

winget's Office package IDs shift between releases — search first to
find the current one for your Windows/Office channel:

```powershell
winget search Microsoft.Office
# Typical current names (verify against the search output):
#   Microsoft.Office              # legacy alias, may still work
#   Microsoft.Office365Apps       # M365 Apps for Enterprise
#   Microsoft.OfficeLTSC.2021     # perpetual LTSC 2021
#   Microsoft.OfficeLTSC.2024     # perpetual LTSC 2024
winget install --silent <the-id-you-just-confirmed>
```

For a firm-wide silent deployment, prefer the **Office Deployment
Tool** with an XML config
(<https://learn.microsoft.com/en-us/deployoffice/overview-office-deployment-tool>) —
gives you channel/version pinning that winget doesn't.

Then sign in with your 365 account. Activation happens automatically;
365 has no problem with VMs.

**Office LTSC 2021 / 2024 (perpetual):**

Use the Office Deployment Tool with an XML config for click-to-run
install, or the matching `Microsoft.OfficeLTSC.*` winget package
above. Perpetual licences activate cleanly in the VFIO guest as long
as the OS install itself is stable (activation is tied to the Windows
install ID, which doesn't change on VM restart).

**Avoid** older Office 2013/2016 perpetual licences in a VM if you
can — they occasionally trigger reactivation after XML changes to the
domain (CPU pinning, memory bumps).

## Enable Excel's GPU rendering

Because Excel sees the real Nvidia GPU here, turn on hardware
graphics acceleration explicitly:

*File ▸ Options ▸ Advanced ▸ Display* → **untick** *Disable
hardware graphics acceleration*.

Nvidia Control Panel per-EXE tweaks are optional here — the Control
Panel doesn't open on muxless-laptop setups (see [doc 05 §3
*Muxless-laptop caveat*](05-windows-guest.md)) and the guest's
*High-Performance* Windows power plan already keeps the dGPU at
working clocks. Confirm Excel is on the dGPU with `nvidia-smi` in an
admin PowerShell inside the guest while Excel is open: `EXCEL.EXE` in
the *Processes* block is the pass condition. GPU memory shows `N/A`
under WDDM — expected, see
[doc 09 § `nvidia-smi` shows `N/A`](09-troubleshooting.md).

## API dev: driving Excel from your engineering scripts

Once Excel lives in the same session, this pattern works out of the
box in both directions.

### Smoke test — Python + xlwings

Repo sample:
[`src/office-integration/python/hello_excel.py`](../src/office-integration/python/hello_excel.py)
— opens a new workbook, writes A1:A2, prints Excel's PID. From an
interactive PowerShell in the guest (Looking Glass or VS Code
Remote-SSH; not plain `ssh windows-eng`, which doesn't hold a COM
session):

```powershell
# Mirror the project to local NTFS so uv's .venv/ stays off virtiofs.
robocopy Z:\office-integration\python C:\dev\office-integration\python /MIR
cd C:\dev\office-integration\python
uv sync
uv run hello_excel.py
```

Expected output:

```
Wrote A1:A2. Excel PID: <N> (see the visible workbook).
```

Excel opens with the two cells populated. `nvidia-smi` in a second
PowerShell lists `EXCEL.EXE` under *Processes* (memory shows `N/A`
under WDDM — see doc 09).

### Full integration examples

**From RhinoCommon C# — dump object metadata:**

```csharp
using Excel = Microsoft.Office.Interop.Excel;

var app  = new Excel.Application { Visible = true };
var wb   = app.Workbooks.Add();
var ws   = (Excel.Worksheet)wb.Worksheets[1];
ws.Cells[1, 1] = "GUID";
ws.Cells[1, 2] = "Volume";
int row = 2;
foreach (var brep in doc.Objects.OfType<Rhino.DocObjects.BrepObject>())
{
    ws.Cells[row, 1] = brep.Id.ToString();
    ws.Cells[row, 2] = brep.BrepGeometry.GetVolume();
    row++;
}
```

Add a NuGet reference to `Microsoft.Office.Interop.Excel` (the
version that ships with the Office you installed).

**From Strand7 automation (Python via `xlwings`):**

```python
import xlwings as xw
book = xw.Book()                          # new workbook
sheet = book.sheets[0]
sheet.range("A1").value = ["Node", "Rx", "Ry", "Rz"]
for i, node in enumerate(nodes_of_interest, start=2):
    reactions = read_reactions(node)      # your St7API wrapper
    sheet.range(f"A{i}").value = [node, *reactions]
book.save(r"C:\Users\Public\reactions.xlsx")
```

`xlwings` uses COM under the hood, so it needs Excel actually
installed in the same VM — which we've now done.

**Bidirectional integration for Grasshopper users:** the *Bumblebee*
plugin gives you live Excel-cell reads/writes from Grasshopper
components. Install it via *Rhino Package Manager* inside the guest.
Same COM constraint applies — Excel must be in the same VM.

## What isn't documented here

- Excel-only automation without Rhino/Strand7 — that's just standard
  Office VBA / xlwings work, no CAD context; the internet has it
  covered.
- OneDrive / SharePoint integration — works fine in the VM (it's just
  Office 365), but slower over the guest's virtio-net than on
  Omarchy directly. If you sync large volumes of files with
  OneDrive, consider putting the OneDrive client on Omarchy
  and exposing the folder to the guest via virtiofs.

## Exit criteria

- Excel opens in the guest, activated, no warnings.
- *File ▸ Options ▸ Advanced ▸ Display* has *Disable hardware
  graphics acceleration* **unticked**, and `nvidia-smi` in the guest
  lists `EXCEL.EXE` in the *Processes* block while Excel is open
  (memory `N/A` under WDDM — expected, see doc 09).
- `uv run hello_excel.py` in `C:\dev\office-integration\python`
  prints `Wrote A1:A2. Excel PID: <N>` and Excel shows the two cells
  populated.
- Optional: same works from Rhino 8's embedded Python 3 component
  (`import xlwings; xw.Book()` inside a Grasshopper CPython
  component) — that Python is separate from the standalone one above.
- Optional: [`omarchy windows vm launch`](https://omarchy.org/manual/windows-vm)
  starts the separate Office-only VM for casual use.

Back to [README](../README.md).
