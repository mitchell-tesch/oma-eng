# 07 — Strand7 R3 setup

Strand7 R3 is a native Windows FEA package. Its automation surface is
`St7API.dll` — a standard 64-bit Windows DLL with a documented C ABI
(the *Strand7 R3 API Reference Manual*). Every language binding (Delphi,
.NET, Python, MATLAB) is a wrapper around this DLL. None of this runs
under Wine reliably. In this VM setup it's a stock Windows install; the
work here is (a) making sure the licence type you have works inside the
guest, (b) verifying OpenGL uses the passed-through Nvidia GPU, and
(c) making `St7API.dll` reachable from your Python and C# code.

## 1. Licence considerations

Four licence models for Strand7 R3 — each has a wrinkle in a VM:

| Licence | Works in this VM? | Notes |
|---|---|---|
| **Cloud licence** (Strand7 CLM) | ✅ Yes — recommended | Sign in through Strand7 with your Strand7 CLM account. The guest just needs outbound HTTPS, which the libvirt default NAT already provides. No dongle, no host-side setup, no reactivation on XML edits. |
| **HASP USB dongle** | ✅ Yes | Pass the USB dongle through with `<hostdev>` `<vendor/product>` in libvirt. Also install the Sentinel HASP runtime in the guest. |
| **Network licence** (Sentinel / Strand7 licence server) | ✅ Yes | Just make sure the guest can route to the licence server on your LAN. `virsh net-dhcp-leases default` for the guest IP if the server has an allow-list. |
| **Node-locked** (older machine-ID lock) | ⚠️ Maybe | The machine ID changes when the guest's virtual hardware changes. Re-activate with Strand7 support after any big XML edit. Best to move to cloud, network, or dongle if you can. |

### Cloud licence — the easy path in a VM

Strand7 R3 introduced cloud licencing (managed via the Strand7 Cloud
Licence Manager, CLM). On first launch of Strand7 R3 the licence dialog
offers *Cloud Licence* — enter the email + password issued to you by
Strand7 Pty Ltd, tick *Remember me*, and you're in. Strand7 caches the
sign-in for subsequent launches.

Practical notes for this VM:

- **No host-side setup**. The libvirt default NAT gives the guest
  outbound HTTPS to `*.strand7.com` for free. If you followed
  [doc 02 §10](02-host-setup.md), UFW is already whitelisting
  `virbr0`, so nothing to open.
- **API uses the same licence pool.** `St7Init()` in the Python and
  C# samples below acquires a licence via the same CLM sign-in as
  `Strand7.exe`. Launch Strand7 once, sign in, close it — the API
  samples then work with no extra credentials.
- **Offline → licence error.** If you're on a plane or the host has
  no Internet, `St7Init()` returns an "unable to acquire licence"
  error. Bring the network back and retry; Strand7 supports
  short-term offline via CLM but the exact policy is set on your
  account, not in the client. See the [Strand7 R3 CLM Setup
  Guide](https://www.strand7.com/r3/Strand7%20R3%20CLM%20Setup%20Guide.pdf).
- **Snapshot revert is safe.** Unlike node-locked, reverting to an
  earlier VM snapshot does not invalidate a cloud licence — the
  entitlement lives on Strand7's side, not tied to any local
  machine ID.

### USB HASP dongle passthrough (if applicable)

Find the dongle vendor/product:

```bash
lsusb
# Bus 001 Device 007: ID 0529:0001 Aladdin Knowledge Systems HASP copy protection dongle
```

Add to the guest XML permanently (already outlined in the template —
uncomment and fill IDs):

```xml
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor  id='0x0529'/>
    <product id='0x0001'/>
  </source>
</hostdev>
```

To hot-attach a dongle to a running guest (useful when the dongle
was plugged in after boot, or when swapping between projects that
use different dongles), use the ready-made
[configs/libvirt/hasp-dongle.xml](../configs/libvirt/hasp-dongle.xml)
template:

```bash
# Edit the vendor/product IDs in configs/libvirt/hasp-dongle.xml first
virsh -c qemu:///system attach-device windows-cad \
    configs/libvirt/hasp-dongle.xml
# ... work ...
virsh -c qemu:///system detach-device windows-cad \
    configs/libvirt/hasp-dongle.xml
```

Then install the Sentinel HASP Runtime in the guest (bundled with the
Strand7 installer, or from Thales' website).

## 2. Install Strand7 R3

Standard Windows installer. Grab it from the Strand7 downloads page
(needs your Strand7 Support & Maintenance login). The install path is
version-specific: `C:\Program Files\Strand7 R31\` for R3.1 releases
(currently R3.1.8), with the API DLL at
`C:\Program Files\Strand7 R31\Bin64\St7API.dll`. The samples in this
repo default to that path — set the `STRAND7_DIR` environment
variable to override.

If your Strand7 installer is on the Omarchy host, drop it into
`~/dev/oma-eng/src/vendor/` and it appears at `Z:\vendor\` in the
guest. Run it from there.

On first launch of Strand7 R3, the licence dialog offers the four
models from §1. Pick *Cloud Licence* and sign in with your CLM
credentials once — the sign-in persists across launches, snapshot
reverts, and API calls.

## 3. Verify graphics

Launch Strand7, `File ▸ Open` a model (either a shipped sample from the
Strand7 install's `Samples\` folder, or drop one of your own into
`~/dev/oma-eng/src/vendor/` on the host — it appears at `Z:\vendor\` in
the guest). Rotate/tumble the model — motion should be smooth at
monitor refresh with no visible tears.

Strand7 R3 does not surface a *Graphics engine / Renderer* pane the way
R2 did — R3 uses hardware-accelerated 3D by default and picks up the
DXGI-primary GPU without user intervention. The reliable check is on
the OS side. In an admin PowerShell inside the guest, with Strand7
sitting on a model view:

```powershell
nvidia-smi
```

The `Processes` block should list `Strand7.exe` with non-zero
`GPU Memory Usage`. If it does, viewport draws are on the passthrough
Nvidia GPU — done.

If `Strand7.exe` is missing from that list, the app is on the QXL /
Microsoft Basic Render Driver fallback. Cross-check via Task Manager
→ *Performance* tab → *GPU* — an idle-looking Nvidia graph while
you spin the Strand7 model confirms the fallback. See doc 09 *Rhino
uses Microsoft Basic Render Driver* for the same fix (disable the
basic display adapter in Device Manager, restart Strand7).

## 4. Confirm the solver uses all guest cores

Strand7 solvers respect thread count from the solver's own
*Parameters* dialog when you kick off a solve (`Solver ▸ Linear Static
▸ Parameters`, etc. — location moved around in R3 vs R2 but the
*Number of threads* input is always on the first parameters page).
Set it to the number of vCPUs allocated to the guest — 10 on this
setup, matching the pinning in doc 03. Global default lives in
Strand7's preferences (menu label depends on R3.1.x version).

## 5. Locate the API DLL

The samples call `St7API.dll` directly via FFI (ctypes in Python,
`[DllImport]` in C#), which mirrors what the *Strand7 R3 API Reference
Manual* documents. No `regsvr32` step needed — `St7API.dll` is a plain
unmanaged native library, not a COM server.

Confirm the DLL exists:

```powershell
Get-Item "C:\Program Files\Strand7 R31\Bin64\St7API.dll"
# should print FullName, Length, LastWriteTime
```

The exact folder name follows the point release: `Strand7 R31\` for the
R3.1 releases (currently the shipping line). If the folder on your box
is different (e.g. `Strand7 R32\`), set the `STRAND7_DIR` environment
variable — both samples read it:

```powershell
setx STRAND7_DIR "C:\Program Files\Strand7 R32\Bin64"
```

(Open a fresh terminal after `setx` for it to take effect.)

### About COM wrappers

Strand7 R3 does not ship a COM wrapper for the API. All shipping
language bindings — the Delphi unit, the C# P/Invoke interop, the
Python ctypes wrapper, and the MATLAB toolbox — go straight through
`St7API.dll` via its C ABI. Older third-party documents that suggest
`regsvr32 St7API.dll` or `CreateObject("St7API.St7")` are describing an
interface that has been retired or never shipped in R3; ignore those.

## 6. Python smoke test

Sample lives at
[`src/strand7-api/python/hello_strand7.py`](../src/strand7-api/python/hello_strand7.py).
It initialises the API, opens a fresh model, adds a node, runs the
linear-static solver (which will stop cleanly on an empty model — that's
fine for a smoke test), closes the file, and releases. From the guest:

```powershell
py Z:\strand7-api\python\hello_strand7.py
```

Standard-library only — `ctypes` ships with Python, no `pip install`
needed. If the script exits with `St7API.dll not found`, check the
`STRAND7_DIR` env var (see §5). If it exits with a Strand7 licence
error out of `St7Init`, see §1 (cloud users: sign in via `Strand7.exe`
first; offline hosts have no cloud-licence checkout).

## 7. C# smoke test

Sample at
[`src/strand7-api/csharp/HelloStrand7/HelloStrand7.cs`](../src/strand7-api/csharp/HelloStrand7/HelloStrand7.cs).
Straight P/Invoke against the DLL — no interop assembly to generate.
Build and run:

```powershell
cd Z:\strand7-api\csharp\HelloStrand7
dotnet build -c Release
dotnet run -c Release
```

The project is x64-only (Strand7 R3 ships a 64-bit DLL). If you get a
`BadImageFormatException`, confirm your dotnet SDK is 64-bit.

## 8. Debug workflow from VS Code (on Omarchy)

VS Code Remote-SSH into the guest, then F5. Each sample ships its own
`.vscode/` directory so first-time setup is one open + one F5.

1. In VS Code on Omarchy → *Remote Explorer* → *SSH* → `windows-cad` →
   *Connect in New Window*.
2. In the new (green) window: *File ▸ Open Folder* → paste
   `Z:\strand7-api\csharp\HelloStrand7` (or `Z:\strand7-api\python`
   for the Python sample).
3. VS Code prompts to install the recommended extensions from the
   shipped `.vscode/extensions.json` on the remote server. Accept once.
4. Set breakpoints in the source; press F5.

**Python** —
[`src/strand7-api/python/.vscode/launch.json`](../src/strand7-api/python/.vscode/launch.json)
ships a `Python: hello_strand7` config. First run in a fresh guest
prompts VS Code to install `debugpy` into the selected Python — say yes.

> **Caveat — debug from a local NTFS copy, not `Z:\`.** Setting
> breakpoints in a Python file that lives on `Z:\` fails with
> `[WinError 1005] The volume does not contain a recognized file
> system`. `debugpy` canonicalises every breakpoint path through
> `os.path.realpath()` → `_getfinalpathname()`, and WinFsp (the driver
> that surfaces virtiofs to Windows) doesn't implement the volume-info
> FSCTL that Win32 call needs. C# / `coreclr` doesn't take this path,
> which is why the C# sample debugs fine from `Z:\`. Fix — mirror the
> Python folder to a local NTFS path in the guest before debugging:
>
> ```powershell
> robocopy Z:\strand7-api\python C:\dev\strand7-api\python /MIR
> ```
>
> Open `C:\dev\strand7-api\python` in VS Code Remote-SSH, F5 there.
> Re-run the `robocopy` to freshen from Omarchy. For a *smoke-test* run
> (no breakpoints), `py Z:\strand7-api\python\hello_strand7.py` from
> §6 keeps working — the caveat is debug-only. See
> [doc 09 § Python debugger fails with `[WinError 1005]`](09-troubleshooting.md).

**C#** —
[`src/strand7-api/csharp/HelloStrand7/.vscode/launch.json`](../src/strand7-api/csharp/HelloStrand7/.vscode/launch.json)
ships a `Launch HelloStrand7` config with a `preLaunchTask: build`
that runs `dotnet build -c Debug` first (see
[`.vscode/tasks.json`](../src/strand7-api/csharp/HelloStrand7/.vscode/tasks.json)).
F5 builds, launches `HelloStrand7.exe` under `coreclr`, and stops on
your breakpoints. If the C# Dev Kit hasn't finished restoring the
project yet you'll see a *couldn't find debug config* toast — wait for
the *Loading solution* status bar to clear and F5 again.

Both configs use `${workspaceFolder}`, so they also work if you clone
the repo directly onto a real Windows workstation later.

## 9. Snapshot

```bash
virsh --connect qemu:///system snapshot-create-as windows-cad rhino-strand7 \
    "Rhino 8 + Grasshopper + Strand7 R3 installed and verified"
```

## Exit criteria

- `nvidia-smi` in the guest lists `Strand7.exe` under *Processes* with
  non-zero GPU memory usage while a model is open.
- Tumbling a shipped sample or one of your own models is smooth at
  monitor refresh.
- Solver thread count is set and a benchmark model finishes with
  expected wall time.
- `hello_strand7.py` from the samples completes without DLL-loading
  errors.
- `dotnet run` in `strand7-api/csharp/` prints "Hello from Strand7 on
  Omarchy."

Continue to [08 — API development workflow](08-api-development.md).
