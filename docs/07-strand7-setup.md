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

Three common licence models for Strand7 R3 — each has a wrinkle in a VM:

| Licence | Works in this VM? | Notes |
|---|---|---|
| **HASP USB dongle** | ✅ Yes | Pass the USB dongle through with `<hostdev>` `<vendor/product>` in libvirt. Also install the HASP runtime in the guest. |
| **Network licence** (Sentinel / Strand7 licence server) | ✅ Yes | Just make sure the guest can route to the licence server on your LAN. `virsh net-dhcp-leases default` for the guest IP if the server has an allow-list. |
| **Node-locked** (older machine-ID lock) | ⚠️ Maybe | The machine ID changes when the guest's virtual hardware changes. Re-activate with Strand7 support after any big XML edit. Best to move to network or dongle if you can. |

### USB HASP dongle passthrough (if applicable)

Find the dongle vendor/product:

```bash
lsusb
# Bus 001 Device 007: ID 0529:0001 Aladdin Knowledge Systems HASP copy protection dongle
```

Add to the guest XML (already outlined in the template — uncomment and
fill IDs):

```xml
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor  id='0x0529'/>
    <product id='0x0001'/>
  </source>
</hostdev>
```

Then install the Sentinel HASP Runtime in the guest (bundled with the
Strand7 installer, or from Thales' website).

## 2. Install Strand7 R3

Standard Windows installer. The install path is version-specific:
`C:\Program Files\Strand7 R31\` for R3.1 releases (current), with the
API DLL at `C:\Program Files\Strand7 R31\Bin64\St7API.dll`. The
samples in this repo default to that path — set the `STRAND7_DIR`
environment variable to override.

If your Strand7 installer is on the Omarchy host, drop it into
`~/src/rhino-omarchy/src/vendor/` and it appears at `Z:\vendor\` in the
guest. Run it from there.

## 3. Verify graphics

Launch Strand7. Open a shipped sample from `File ▸ Open Sample`
(typical samples: `TESTOGL.ST7` for the graphics test scene,
`Truss.ST7` for a small linear-static model — actual samples vary
by installer options). Rotate/tumble in the model
window — motion should be smooth at monitor refresh with no visible tears.

*Tools ▸ Preferences ▸ Graphics*:

- **Graphics engine**: `OpenGL`
- **Renderer**: should read `NVIDIA GeForce RTX ...` — matches the dGPU.
- If it reads `GDI Generic`, Strand7 is on the QXL fallback; see doc 09.

Run the shipped `TESTOGL.ST7` scene (`File ▸ Open Sample ▸ TESTOGL.ST7`)
and step through the display test — nothing should stutter.

## 4. Confirm the solver uses all guest cores

Strand7 solvers respect thread count from *Tools ▸ Preferences ▸ Solvers
▸ Threads*. Set it to the number of vCPUs you allocated to the guest
(matching your CPU pinning in doc 03).

Bench with the shipped `LSA-Beam.ST7` or one of your own linear-static
models; runtimes should scale linearly with allocated cores.

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
py Z:\src\rhino-omarchy\src\strand7-api\python\hello_strand7.py
```

Standard-library only — `ctypes` ships with Python, no `pip install`
needed. If the script exits with `St7API.dll not found`, check the
`STRAND7_DIR` env var (see §5).

## 7. C# smoke test

Sample at
[`src/strand7-api/csharp/HelloStrand7.cs`](../src/strand7-api/csharp/HelloStrand7.cs).
Straight P/Invoke against the DLL — no interop assembly to generate.
Build and run:

```powershell
cd Z:\src\rhino-omarchy\src\strand7-api\csharp
dotnet build -c Release
dotnet run -c Release
```

The project is x64-only (Strand7 R3 ships a 64-bit DLL). If you get a
`BadImageFormatException`, confirm your dotnet SDK is 64-bit.

## 8. Debug workflow from VS Code (on Omarchy)

Same story as the Rhino docs — VS Code Remote-SSH into the guest, F5 to
launch or attach:

- For **Python**, use the standard *Python: Current File* debug
  configuration. Set breakpoints on the Omarchy side; they hit in the
  guest.
- For **C#**, use the *.NET: Launch* configuration in the template (this
  runs the just-built `HelloStrand7.exe`).

## 9. Snapshot

```bash
virsh --connect qemu:///system snapshot-create-as windows-cad rhino-strand7 \
    "Rhino 8 + Grasshopper + Strand7 R3 installed and verified"
```

## Exit criteria

- Strand7 → *Preferences ▸ Graphics* shows the Nvidia GPU as renderer.
- `TESTOGL.ST7` runs smooth at monitor refresh.
- Solver thread count is set and a benchmark model finishes with
  expected wall time.
- `hello_strand7.py` from the samples completes without DLL-loading
  errors.
- `dotnet run` in `strand7-api/csharp/` prints "Hello from Strand7 on
  Omarchy."

Continue to [08 — API development workflow](08-api-development.md).
