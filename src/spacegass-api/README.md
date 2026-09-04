# src/spacegass-api

Samples for driving **SPACE GASS 14.5+** via its official **REST HTTP API**.

The SPACE GASS API is a headless local HTTP service — `SpaceGassApi.exe`
— that ships alongside SPACE GASS 14.5. It runs on `http://localhost:34560`
by default, exposes a full OpenAPI 3 surface (job files, structure,
sections, materials, loads, analysis, results), and needs no
authentication. Vendor docs: <https://api.spacegass.com/docs/overview>.

No COM Dispatch. No `.sg2` text-file scraping. No CLI batch flags.
The two previous placeholder scripts (`hello_spacegass_batch.py` and
`hello_spacegass_com.py`) were removed — those interfaces never
existed in shipping SPACE GASS.

## Contents

| Path | What it does | Approach |
|---|---|---|
| [`python/hello_spacegass.py`](python/hello_spacegass.py) | Opens the built-in `Portal Frame.SG` sample, lists nodes, closes. | `space-gass-api` pip package (async) |
| [`python/hello_spacegass_analysis.py`](python/hello_spacegass_analysis.py) | Opens Portal Frame, runs a linear-static solve, polls progress, prints node reactions. | `space-gass-api` pip package (async) |
| [`csharp/HelloSpaceGass/`](csharp/HelloSpaceGass/) | C# equivalent of `hello_spacegass.py` — Quick Start via the .NET SDK. | `SpaceGassApi` NuGet package |

Both samples are modelled on the vendor examples in
[SpaceGass/space-gass-api](https://github.com/SpaceGass/space-gass-api)
so users can lift them straight into their own projects.

## Prereqs (guest side)

- **SPACE GASS 14.5 or later** installed and licensed.
- SPACE GASS opened at least once (initialises the API data files).
- The API service running:
  - Easiest: double-click the **SPACE GASS API** shortcut under the
    SPACE GASS Windows application folder.
  - CLI: `"C:\Program Files\SPACE GASS 14.5\SpaceGassApi.exe"` (add
    `--port=NNNNN` to change the port).
- For the Python samples: `py -m pip install --user -r requirements.txt`
  (installs [`space-gass-api`](https://pypi.org/project/space-gass-api/)).
- For the C# sample: `dotnet restore` pulls
  [`SpaceGassApi`](https://www.nuget.org/packages/SpaceGassApi) from NuGet.

## Run

```powershell
# Start SpaceGassApi.exe first (or leave it running in the background)

cd Z:\src\rhino-omarchy\src\spacegass-api\python
py -m pip install --user -r requirements.txt
py hello_spacegass.py
py hello_spacegass_analysis.py

cd Z:\src\rhino-omarchy\src\spacegass-api\csharp\HelloSpaceGass
dotnet run
```

## Running from Omarchy instead of inside the guest

Because the SPACE GASS API is plain HTTP with no authentication, the
samples don't strictly need to run inside the Windows guest — they just
need to reach `SpaceGassApi.exe` on port 34560. Two easy paths:

- **Directly hit the guest IP.** From an admin PowerShell in the guest,
  allow the port through Windows Firewall:
  ```powershell
  New-NetFirewallRule -DisplayName "SPACE GASS API" -Direction Inbound `
      -Protocol TCP -LocalPort 34560 -Action Allow
  ```
  Find the guest IP on Omarchy with `virsh net-dhcp-leases default`,
  then run the samples on the host:
  ```bash
  py hello_spacegass.py http://192.168.122.42:34560
  ```
- **SSH port forward.** `ssh -L 34560:localhost:34560 windows-cad`
  from Omarchy, then run the samples on the host against
  `http://localhost:34560`. No firewall change needed.

This is the one API in the repo that doesn't require in-session COM
or in-process DLL loading — the passthrough VM is only needed if
SPACE GASS's own GUI is being driven. Automation-only workflows can
sit entirely on Omarchy.

Cross-reference: [docs/11-etabs-and-spacegass.md](../../docs/11-etabs-and-spacegass.md).