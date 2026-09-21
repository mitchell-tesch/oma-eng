# src/ — API sample projects

This directory is bind-mounted into the Windows guest as **`Z:\`** via
virtiofs (see `<filesystem>` block in
[../configs/libvirt/windows-cad.xml](../configs/libvirt/windows-cad.xml)).
Edit any of these files from Omarchy — the guest sees the change
instantly. Build and run in the guest.

## Contents

| Path | What it is | Language | Build |
|---|---|---|---|
| `rhino-plugin/` | Minimal Rhino 8 plugin (`.rhp`) — registers a `_HelloRhino` command | C# / .NET 7 | `dotnet build` |
| `grasshopper-component/` | Minimal Grasshopper 1 component (`.gha`) | C# / .NET 7 | `dotnet build` |
| `strand7-api/python/` | Strand7 R3 automation — initialises the API, creates a tiny model, runs the solver as a smoke test | Python 3 (ctypes) | `py hello_strand7.py` |
| `strand7-api/csharp/HelloStrand7/` | Same as above but P/Invoke from C# | C# / .NET 8 | `dotnet run` |
| `office-integration/python/` | Strand7 → Excel: run LSA, dump reactions to a formatted `.xlsx` via `xlwings` | Python 3 + xlwings | `py strand7_to_excel.py` |
| `office-integration/csharp/RhinoToExcel/` | Rhino `_RhinoToExcel` command — dumps selected/all objects' metadata to Excel via late-bound COM | C# / .NET 7 + RhinoCommon | `dotnet build` |
| `etabs-api/csharp/HelloETABS/` | ETABS 22 OAPI — starts ETABS, builds a cantilever column, runs LSA, prints base reaction | C# / .NET 8 (late-bound COM) | `dotnet run` |
| `sap2000-api/` | **Doc only** — port `HelloETABS` to SAP2000 26 with a two-line ProgID + file-extension swap. See the folder README. | — | — |
| `spacegass-api/python/hello_spacegass.py` | SPACE GASS 14.5+ REST — opens sample, lists nodes, closes | Python 3 + `space-gass-api` (async) | `py hello_spacegass.py` |
| `spacegass-api/python/hello_spacegass_analysis.py` | SPACE GASS 14.5+ REST — opens sample, runs LSA, reads reactions | Python 3 + `space-gass-api` (async) | `py hello_spacegass_analysis.py` |
| `spacegass-api/csharp/HelloSpaceGass/` | C# equivalent of the Python quick-start | C# / .NET 8 + `SpaceGassApi` NuGet | `dotnet run` |

## Running from the guest

Open a PowerShell in the guest (or an SSH session from Omarchy):

```powershell
# Rhino plugin
cd Z:\rhino-plugin
dotnet build -c Debug
# Then in Rhino: drag-and-drop the .rhp onto Rhino, or
#   _-LoadPlugIn "bin\Debug\net7.0-windows\HelloRhino.rhp"
# Type: _HelloRhino

# Grasshopper component
cd Z:\grasshopper-component
dotnet build -c Debug
Copy-Item bin\Debug\net7.0-windows\HelloGh.gha $env:APPDATA\Grasshopper\Libraries\

# Strand7 Python
cd Z:\strand7-api\python
py hello_strand7.py

# Strand7 C#
cd Z:\strand7-api\csharp\HelloStrand7
dotnet run -c Release

# Strand7 -> Excel (Python + xlwings, managed with uv)
cd Z:\office-integration\python
uv sync
uv run strand7_to_excel.py

# Rhino -> Excel (C# Rhino command via late-bound COM)
cd Z:\office-integration\csharp\RhinoToExcel
dotnet build -c Debug
# Then in Rhino: drag-and-drop the .rhp onto Rhino, or
#   _-LoadPlugIn "bin\Debug\net7.0-windows\RhinoToExcel.rhp"
# Type: _RhinoToExcel  (nothing selected = whole document; or select first)

# ETABS 22 OAPI (C# console)
cd Z:\etabs-api\csharp\HelloETABS
dotnet run -c Release

# SPACE GASS 14.5+ REST API — quick start (Python via uv)
# First: start SpaceGassApi.exe in the guest.
cd Z:\spacegass-api\python
uv sync
uv run hello_spacegass.py

# SPACE GASS 14.5+ REST API — run linear-static + reactions (Python)
uv run hello_spacegass_analysis.py

# SPACE GASS 14.5+ REST API — C# equivalent
cd Z:\spacegass-api\csharp\HelloSpaceGass
dotnet run
```

## Why the samples are minimal

Each sample demonstrates the build-load-execute cycle end-to-end from
Omarchy: once a sample prints its "hello" you know the pipeline
(edit on host, build in guest, run against real GPU, debug from Omarchy
VS Code) is working for that ecosystem. Extend from there into
project-specific code.
