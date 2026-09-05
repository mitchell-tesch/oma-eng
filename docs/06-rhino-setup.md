# 06 — Rhino 8 + Grasshopper setup

Rhino 8 in the guest is an ordinary Windows install; the interesting bits
are (a) confirming Rhino is using the real Nvidia GPU (not the QXL
fallback), (b) turning on **Cycles CUDA/OptiX** for GPU rendering, and
(c) getting Grasshopper to load without complaining about virtiofs.

## 1. Install Rhino 8

Grab the installer from <https://www.rhino3d.com/download/>. Run it in the
guest. Sign in with Cloud Zoo *or* enter a standalone licence key.

If you use a Zoo licence server on your LAN, add its address in
*Tools ▸ Options ▸ Licenses*. `virsh net-dhcp-leases default` shows
your guest's IP if the Zoo server needs a static allow-list.

## 2. Verify the GPU

`_SystemInfo` in Rhino's command line prints an OpenGL block near the
top. Example output (exact fields and values vary by GPU / driver
version):

```
OpenGL Settings
  Safe mode:      Off
  Use accelerated hardware modes:  True
  Redraw scene when viewports are exposed:  True
  Graphics level being used:   OpenGL 4.6 (primary GPU's maximum)
  Render version:              4.6
  Shading Language:            4.60 NVIDIA
  Driver Date:                 X-YY-ZZZZ
  Driver Version:              572.XX
  Maximum Texture size:        32768 x 32768
  Z-Buffer depth:              24 bits
  Maximum Viewport size:       32768 x 32768
  Total Video Memory:          XX GB
```

If it says `GDI Generic` or `Microsoft Basic Render Driver`, Rhino is
still on the QXL fallback — see [09 — Troubleshooting](09-troubleshooting.md)
*Rhino uses Microsoft Basic Render Driver*.

## 3. Turn on Cycles GPU rendering (Rhino Render)

Rhino 8's built-in renderer is Cycles. Default is CPU; switch it to GPU:

*Tools ▸ Options ▸ Rhino Render* → set:

- **Device**: `Optix` (Turing+) or `Cuda`
- **GPU**: the Nvidia device (the only choice)
- **Threads**: leave default
- **Tile size**: 256

The device tabs (CPU / CUDA / OptiX / OpenCL) each show a readiness
indicator and a *Recompile kernels* button — hit that once after a
driver update. Then `_Render`. First job compiles OptiX kernels
(30–60 s); subsequent jobs are fast. If Cycles falls back to CPU with
an error about "could not create device", the Nvidia driver may be
too old — install the current Studio Driver.

## 4. Grasshopper — virtiofs autosave workaround

Grasshopper writes recovery files next to the open `.gh` file. On
non-NTFS shares (network drives, some virtualisation file-shares) it
occasionally logs `access denied` on autosave. There's no confirmed
virtiofsd bug behind this specifically, but if you hit the error two
things reliably clear it:

**A) Update virtiofsd** — the `qemu-full` package on current Arch ships
the Rust-based virtiofsd, which is the recommended one. Confirm with:

```bash
virtiofsd --version         # want 1.10+ (Rust rewrite)
```

If you're on the old C virtiofsd shipped alongside older qemu, uninstall
it and install `virtiofsd` from repos.

**B) Point Grasshopper autosave at a local NTFS path** — in
Grasshopper: *File ▸ Preferences ▸ Files* → *Autosave folder* →
`C:\GH-Autosave`. This is the reliable fix regardless of the underlying
cause.

Recommended: do both.

## 5. Grasshopper Python (IronPython 2 and CPython 3)

Rhino 8 ships Grasshopper 1 with two Python script components:

- Legacy **Python 2** component — IronPython 2.7.12.
- New **Python 3 (CPython)** component — embedded CPython 3.9.11.
  Supports `numpy`, `scipy`, and `pip install`.

Grasshopper 2, still a WIP by David Rutten, is not shipped in Rhino 8
— it targets Rhino 9. Everything in this repo is Grasshopper 1 API.

For CPython 3 install `numpy` etc via the component's own package
manager: right-click the component → the *Packages* / *Manage
Packages* entry (label wording depends on Rhino 8 version).

## 6. .NET plugin (`.rhp` / `.gha`) workflow

- Repo project templates live under [`src/rhino-plugin/`](../src/rhino-plugin/)
  and [`src/grasshopper-component/`](../src/grasshopper-component/).
- Build in the guest (they reference `RhinoCommon` NuGet, so they build
  anywhere; but debug requires Rhino running in the guest):

  ```powershell
  cd Z:\src\oma-eng\src\rhino-plugin
  dotnet build -c Debug
  ```

- Register the plugin, choose one of:
  - `_PlugInManager` in Rhino → *Install* → point at
    `bin\Debug\net7.0-windows\HelloRhino.rhp`.
  - Drag-and-drop the `.rhp` onto the Rhino window.
  - `_-LoadPlugIn "bin\Debug\net7.0-windows\HelloRhino.rhp"` at the
    Rhino command line (the leading dash suppresses the file-picker).
- For Grasshopper, drop the `.gha` into
  `%APPDATA%\Grasshopper\Libraries\` (or use a junction to `Z:\...\bin`).

### If you're on Rhino 9

Rhino 9 shifts the RhinoCommon target framework from `net7.0-windows`
to `net8.0-windows`. To retarget the samples in this repo:

1. In every `.csproj` that references `RhinoCommon`
   ([HelloRhino](../src/rhino-plugin/HelloRhino.csproj),
   [HelloGh](../src/grasshopper-component/HelloGh.csproj),
   [RhinoToExcel](../src/office-integration/csharp/RhinoToExcel/RhinoToExcel.csproj)),
   change the target framework:

   ```xml
   <TargetFramework>net8.0-windows</TargetFramework>
   ```

2. Bump the `RhinoCommon` package version to the 9-series wildcard:

   ```xml
   <PackageReference Include="RhinoCommon" Version="9.*-*" ExcludeAssets="runtime" />
   ```

   (`Grasshopper` NuGet in [HelloGh](../src/grasshopper-component/HelloGh.csproj)
   likewise.)

3. Update the build-output paths in this doc and in the guest install
   commands from `net7.0-windows` to `net8.0-windows`.

The plugin architecture and RhinoCommon APIs used by the samples
haven't changed shape across the 8→9 boundary — no code edits
needed.

## 7. Debug from VS Code (Omarchy) into Rhino (guest)

Because you have Remote-SSH, launching Rhino from VS Code is trivial:

`launch.json` in the plugin project (already in the template):

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Attach to Rhino",
      "type": "coreclr",
      "request": "attach",
      "processId": "${command:pickProcess}"
    }
  ]
}
```

Use `"type": "coreclr"` for Rhino 8 (net7.0-windows). For legacy Rhino
6/7 targeting .NET Framework, use `"type": "clr"` instead.

Steps:

1. Start Rhino in the guest and load your plugin
   (`_-LoadPlugIn "path\to\HelloRhino.rhp"`).
2. In VS Code (connected via Remote-SSH to the guest) press F5 →
   *Attach to Rhino* → pick `Rhino.exe` from the process list.
3. Set breakpoints in your C# on the Omarchy side; they hit in the guest.

## 8. Rhino.Compute (optional)

If you also want a headless compute service for grasshopper-as-a-service:

```powershell
git clone https://github.com/mcneel/compute.rhino3d.git
cd compute.rhino3d\src
dotnet run --project compute.geometry
```

Bind it to `127.0.0.1:5000` or expose to the host over virtio-net. There's
no reason not to run this in the guest even though it's headless — it
needs the Rhino runtime.

## Exit criteria

- Rhino's `_SystemInfo` shows the Nvidia dGPU as the OpenGL device.
- Cycles renders a test scene on GPU (OptiX) in the guest.
- `HelloRhinoCommand` from [`src/rhino-plugin/`](../src/rhino-plugin/)
  loads and prints "Hello from Rhino on Omarchy!" in the command line.
- Grasshopper opens and saves `.gh` files from `Z:\` without autosave
  errors.
- VS Code Remote debug attaches to `Rhino.exe`.

Continue to [07 — Strand7 R3 setup](07-strand7-setup.md).
