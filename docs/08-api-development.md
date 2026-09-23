# 08 — API development workflow

The whole reason for this setup is that you can edit Rhino/Grasshopper
plugins and Strand7 automation scripts from Omarchy exactly as if they
were native, while the runtime lives inside the Windows guest. This
page ties the pieces together.

## The mental model

```
  Omarchy (Hyprland, VS Code, Git, terminal)
        │
        │   Edit files under ~/dev/oma-eng/src/            (this repo)
        │   Edit files under ~/dev/<sibling-repo>/         (any other repo)
        ▼
  virtiofs shares ────────────────────────► Z:\  in the guest  (this repo's src/)
                                            Y:\  in the guest  (whole ~/dev/ tree)
        ▲                                     │
        │                                     │  Build / debug
        │                                     ▼
  Remote-SSH  ◄─────────────  OpenSSH server  Rhino.exe / Strand7.exe
                                              │
                                              ▼
                              Nvidia dGPU (via VFIO)
```

- **Edit** on Omarchy — because that's your desktop, git, editor, tmux.
- **Build & run** in the guest — because the SDKs (RhinoCommon, Strand7
  COM) only exist on Windows.
- **Debug** in VS Code Remote-SSH — one keystroke round trip.

Two virtiofs shares ship with `configs/libvirt/windows-eng.xml`:

- **`Z:`** ↔ `~/dev/oma-eng/src/` (this repo's source tree). All the
  sample project paths in this doc use `Z:\`.
- **`Y:`** ↔ `~/dev/` (the parent — every repo you clone alongside
  `oma-eng`). Use `Y:\<repo>\` when working on sibling projects that
  aren't part of oma-eng itself.

To add more shares later, use
[`scripts/set-guest-share`](../scripts/set-guest-share) — it edits
the XML, hot-attaches the device to the live guest, and prints the
`sc.exe create` snippet for the paired Windows service. See doc 03
§6 for the initial `Y:` service install.

## Directory layout under `src/`

```
src/
├── rhino-plugin/                RhinoCommon C# plugin (.rhp)
│   ├── HelloRhinoPlugin.cs
│   ├── HelloRhinoCommand.cs
│   └── HelloRhino.csproj
├── grasshopper-component/       Grasshopper .gha component
│   ├── HelloGhComponent.cs
│   └── HelloGh.csproj
├── strand7-api/                 Strand7 R3 automation
│   ├── python/
│   │   └── hello_strand7.py
│   └── csharp/
│       └── HelloStrand7/
│           ├── HelloStrand7.cs
│           └── HelloStrand7.csproj
├── office-integration/          Excel automation from Rhino and Strand7
│   ├── python/
│   │   ├── strand7_to_excel.py
│   │   ├── pyproject.toml
│   │   └── uv.lock
│   └── csharp/
│       └── RhinoToExcel/         Rhino _RhinoToExcel command
│           ├── RhinoToExcelPlugin.cs
│           ├── RhinoToExcelCommand.cs
│           └── RhinoToExcel.csproj
├── etabs-api/                   CSi ETABS 22 OAPI
│   └── csharp/
│       └── HelloETABS/
│           ├── Program.cs
│           └── HelloETABS.csproj
└── spacegass-api/               SPACE GASS 14.5+ REST API
    ├── python/
    │   ├── hello_spacegass.py
    │   ├── hello_spacegass_analysis.py
    │   ├── pyproject.toml
    │   └── uv.lock
    └── csharp/
        └── HelloSpaceGass/
            ├── Program.cs
            └── HelloSpaceGass.csproj
```

## Editing from Omarchy, running in the guest

VS Code on Omarchy → *Remote Explorer* → *SSH* → `windows-eng` →
*Connect in New Window*. In the new (green) window: *File ▸ Open
Folder* → paste `Z:\` (or a specific project folder such as
`Z:\rhino-plugin` or `Z:\strand7-api\csharp\HelloStrand7`).

`Z:\` in the guest is the same inode as `~/dev/oma-eng/src/` on the
host, via virtiofs. Edit either place, the other sees it immediately
— not sync, the same file.

**SSH-session `Z:` caveat** — VirtIO-FS Service mounts `Z:` per
interactive user session. Plain `ssh windows-eng` opens a
non-interactive session that doesn't inherit that mapping, so
`dir Z:\` errors with *"The system cannot find the path specified."*
Workarounds:

- **VS Code Remote-SSH** does inherit `Z:` (it starts a full
  interactive session for the remote server), so building and
  running via VS Code works.
- **Plain SSH**: run the command through PowerShell's user-session
  helper, e.g. `ssh windows-eng "powershell -Command 'net use Z: /persistent:no & cd Z:\\ & dotnet build'"`
  — or add a persistent `net use` in a Task Scheduler *At log on*
  task that runs at boot with the SYSTEM account.

Both `uv sync` and `dotnet build` in the samples below assume you
launched them from an interactive session (Remote-SSH or a Looking
Glass PowerShell) rather than plain `ssh windows-eng`.

### Building

```powershell
# In the guest, via SSH or Remote-SSH terminal
cd Z:\rhino-plugin
dotnet build -c Debug
```

For Grasshopper components:

```powershell
cd Z:\grasshopper-component
dotnet build -c Debug
```

For the Strand7 C# sample:

```powershell
cd Z:\strand7-api\csharp\HelloStrand7
dotnet build -c Release
```

The Rhino plugin project uses the `RhinoCommon` and `Grasshopper`
NuGet packages from nuget.org — no local Rhino install needed to
*build*, only to run/debug.

## Loading a plugin the fast way

```powershell
# From the guest, once built:
$rhp = "$PWD\bin\Debug\net7.0-windows\HelloRhino.rhp"
Start-Process "C:\Program Files\Rhino 8\System\Rhino.exe" -ArgumentList "/nosplash", "/runscript=`"_-LoadPlugIn \"$rhp\" _EnterEnd\""
```

Or drop a symlink so Rhino auto-loads on next start:

```powershell
New-Item -ItemType SymbolicLink `
    -Path "$env:APPDATA\McNeel\Rhinoceros\8.0\Plug-ins\HelloRhino" `
    -Target "$PWD\bin\Debug\net7.0-windows"
```

## Debugging

VS Code Remote-SSH into the guest, F5. Each sample folder ships its
own `.vscode/launch.json` with the right mode:

- **Rhino / Grasshopper plugins** — *attach* via
  [`src/rhino-plugin/.vscode/launch.json`](../src/rhino-plugin/.vscode/launch.json)
  (`type: coreclr`, `processName: Rhino.exe`). Launch Rhino in the
  guest, load the plugin, F5 — attaches to the single `Rhino.exe`
  without a process picker. Grasshopper `.gha` components attach the
  same way (Rhino hosts Grasshopper in-process).
- **Strand7 C# sample** — *launch* via
  [`src/strand7-api/csharp/HelloStrand7/.vscode/launch.json`](../src/strand7-api/csharp/HelloStrand7/.vscode/launch.json)
  with a `dotnet build -c Debug` `preLaunchTask`. `HelloStrand7.exe`
  is a standalone console app driving Strand7 through `St7API.dll` —
  no `Strand7.exe` GUI process to attach to. F5 builds, launches,
  hits your breakpoints.
- **Python samples** — `debugpy` launch via each sample's
  `.vscode/launch.json` (e.g.
  [`src/strand7-api/python/.vscode/launch.json`](../src/strand7-api/python/.vscode/launch.json)).
  Install the *Python* extension in the remote window on first open.
  Set `"justMyCode": false` in the config if you want to step into
  `pywin32`.

> **Python + virtiofs caveat.** Setting breakpoints in a `.py` file
> under `Z:\` fails with `OSError: [WinError 1005]` — `debugpy` calls
> `os.path.realpath()` and WinFsp doesn't implement the underlying
> Win32 volume-info FSCTL. For breakpoint-driven Python debug, mirror
> the folder to a local NTFS path in the guest first:
> `robocopy Z:\<project> C:\dev\<project> /MIR`, then open the C:\
> copy in Remote-SSH. C# / `coreclr` is unaffected. Full detail in
> [doc 09 § Python debugger fails with `[WinError 1005]`](09-troubleshooting.md).

## Source control

Do all your `git` on **Omarchy** (or in a WSL if you insist — but there
is no WSL here, so just Omarchy). Git on Windows over virtiofs is
possible but has line-ending and permission quirks; skip it.

```bash
cd ~/dev/oma-eng
git status
git add -A && git commit -m "..." && git push
```

## Package caches

The .NET SDK in the guest maintains its own NuGet cache at
`C:\Users\<you>\.nuget\packages`. Don't put it on virtiofs — MSBuild
does a lot of small stats, and even fast virtiofs is slower than the
guest's local NTFS for that workload.

Same for `Grasshopper\Libraries` — keep them on the guest's `C:` drive.

## When you don't need the GPU pass-through

Everything in this repo needs a Windows runtime — RhinoCommon,
Grasshopper, `St7API.dll`, CSi OAPI. None run natively on Linux. What
you *can* skip when the workload is purely headless (`Rhino.Compute`
serving geometry over HTTP, a nightly FEA batch, an unattended ETABS
run) is the **GPU pass-through and Looking Glass**. Boot the guest
without the `<hostdev>` GPU block attached, drive it via SSH, and
give the 24 GiB of hugepages back to the host. `Rhino.Compute` still
runs *inside the guest* — there's no Linux build of it in Rhino 8.
See the [Rhino Compute docs](https://developer.rhino3d.com/guides/compute/)
and [doc 06 §8](06-rhino-setup.md).

For anything that touches Grasshopper's canvas, a Strand7 model view,
or any UI at all, you need the VM with GPU + LG.

## Exit criteria

- Editing `HelloRhinoCommand.cs` in Omarchy VS Code, saving, and
  rebuilding + reloading in the guest gives an updated
  `_HelloRhino` command output.
- Setting a breakpoint in `HelloGhComponent.SolveInstance()` and
  triggering it from a Grasshopper canvas in the guest hits the
  breakpoint in Omarchy's VS Code.
- `hello_strand7.py` runs to completion via
  `py Z:\strand7-api\python\hello_strand7.py` in a guest PowerShell;
  editing a value on Omarchy and re-running reflects the change
  immediately. (For breakpoint-driven Python debug the file must live
  on local NTFS, not `Z:\` — see Debugging above.)

Continue to [09 — Troubleshooting](09-troubleshooting.md).
