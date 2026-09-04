# 08 — API development workflow

The whole reason for this setup is that you can edit Rhino/Grasshopper
plugins and Strand7 automation scripts from Omarchy exactly as if they
were native, while the runtime lives inside the Windows guest. This
page ties the pieces together.

## The mental model

```
  Omarchy (Hyprland, VS Code, Git, terminal)
        │
        │   Edit files under ~/src/rhino-omarchy/src/
        ▼
  virtiofs share ─────────────────────────► Z:\src\  in the guest
        ▲                                     │
        │                                     │  Build / debug
        │                                     ▼
  Remote-SSH  ◄─────────────  OpenSSH server  Rhino.exe / St7.exe
                                              │
                                              ▼
                              Nvidia dGPU (via VFIO)
```

- **Edit** on Omarchy — because that's your desktop, git, editor, tmux.
- **Build & run** in the guest — because the SDKs (RhinoCommon, Strand7
  COM) only exist on Windows.
- **Debug** in VS Code Remote-SSH — one keystroke round trip.

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
│       ├── HelloStrand7.cs
│       └── HelloStrand7.csproj
├── office-integration/          Excel automation from Rhino and Strand7
│   ├── python/
│   │   ├── strand7_to_excel.py
│   │   └── requirements.txt
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
    │   └── requirements.txt
    └── csharp/
        └── HelloSpaceGass/
            ├── Program.cs
            └── HelloSpaceGass.csproj
```

## Editing from Omarchy, running in the guest

Open the whole tree remote:

```bash
code --remote ssh-remote+windows-cad ~/src/rhino-omarchy/src
```

The `src/` folder in the remote window is `Z:\src\rhino-omarchy\src\` (via
virtiofs), which is the same inode as `~/src/rhino-omarchy/src` on the
host. Edit either place, the other sees it. This is not sync — it's the
same file.

### Building

```powershell
# In the guest, via SSH or Remote-SSH terminal
cd Z:\src\rhino-omarchy\src\rhino-plugin
dotnet build -c Debug
```

For Grasshopper components:

```powershell
cd Z:\src\rhino-omarchy\src\grasshopper-component
dotnet build -c Debug
```

For the Strand7 C# sample:

```powershell
cd Z:\src\rhino-omarchy\src\strand7-api\csharp
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

`launch.json` in each C# project has a *Attach to Rhino* / *Attach to
Strand7* configuration. Steps:

1. Rhino/Strand7 already running in the guest.
2. VS Code (Remote-SSH into guest) → *Run and Debug* → pick config.
3. VS Code prompts for a process; pick `Rhino.exe` / `St7.exe`.
4. Breakpoints on Omarchy hit inside the guest process.

For pure `dotnet run` executables (Strand7 C# sample) use the *Launch*
config — F5 launches under debugger.

For Python, install the *Python* extension in the remote window; the
default *Debug Current File* config works. Set `"justMyCode": false` in
`launch.json` if you want to step into `pywin32`.

## Source control

Do all your `git` on **Omarchy** (or in a WSL if you insist — but there
is no WSL here, so just Omarchy). Git on Windows over virtiofs is
possible but has line-ending and permission quirks; skip it.

```bash
cd ~/src/rhino-omarchy
git status
git add -A && git commit -m "..." && git push
```

## Package caches

The .NET SDK in the guest maintains its own NuGet cache at
`C:\Users\<you>\.nuget\packages`. Don't put it on virtiofs — MSBuild
does a lot of small stats, and even fast virtiofs is slower than the
guest's local NTFS for that workload.

Same for `Grasshopper\Libraries` — keep them on the guest's `C:` drive.

## When to *not* build in the guest

Rhino 8's headless mode (`Rhino.Inside`, `Rhino.Compute`) works on
Linux for pure geometry work. If you're building a service that only
needs geometric operations (mesh, brep, curve maths) and no UI, you can
skip the VM entirely and run `Rhino.Compute` on Omarchy directly. See
the [Rhino Compute docs](https://developer.rhino3d.com/guides/compute/)
and doc 06 §8.

For anything that touches Grasshopper's document model, the Strand7 COM
API, or any UI, you need the VM.

## Exit criteria

- Editing `HelloRhinoCommand.cs` in Omarchy VS Code, saving, and
  rebuilding + reloading in the guest gives an updated
  `_HelloRhino` command output.
- Setting a breakpoint in `HelloGhComponent.SolveInstance()` and
  triggering it from a Grasshopper canvas in the guest hits the
  breakpoint in Omarchy's VS Code.
- `hello_strand7.py` runs to completion; changing a value in the
  script from Omarchy and re-running from the guest reflects the change
  immediately.

Continue to [09 — Troubleshooting](09-troubleshooting.md).
