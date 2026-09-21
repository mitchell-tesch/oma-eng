# src/sap2000-api

Samples for driving **CSi SAP2000 26** via its OAPI (Open API).

SAP2000 shares the CSi OAPI with ETABS — same `CSiAPIv1` interop
namespace, same `cSapModel` interfaces, same units enum. Two lines
differ. Rather than shipping a near-duplicate sample project, this
directory documents the port from [`../etabs-api/csharp/HelloETABS/`](../etabs-api/csharp/HelloETABS/)
so you don't maintain two copies of the same code.

## The two-line port

Starting from [HelloETABS/Program.cs](../etabs-api/csharp/HelloETABS/Program.cs):

```diff
- private const string ProgID = "CSI.ETABS.API.ETABSObject";
+ private const string ProgID = "CSI.SAP2000.API.SapObject";
```

```diff
- var modelPath = @"C:\Users\Public\HelloETABS_scratch.edb";
+ var modelPath = @"C:\Users\Public\HelloSAP2000_scratch.sdb";
```

Everything else — `PointObj.AddCartesian`, `FrameObj.AddByPoint`,
`LoadPatterns.Add`, `PointObj.SetLoadForce`, `Analyze.RunAnalysis`,
`Results.JointReact` — is identical. `eUnits.kip_in_F` (value `3`)
means the same in both apps.

## Full walk-through

See [docs/11-etabs-and-spacegass.md § SAP2000 — OAPI](../../docs/11-etabs-and-spacegass.md)
for the complete SAP2000 install + API story, including the CSi
Reprise licence-pool sharing with ETABS.

## Prereqs

- SAP2000 26 (or 25) installed and licensed in the guest.
- COM component registered — the SAP2000 installer does this by
  default. Confirm from an admin PowerShell:
  ```powershell
  Get-ChildItem "HKLM:\SOFTWARE\Classes\CSI.SAP2000.API.SapObject"
  ```

## Run

Copy `HelloETABS/` to `HelloSAP2000/` in your own working tree
(don't add it back to this repo — the whole point of this README is
to avoid the duplicate), apply the two-line diff above, then:

```powershell
cd Z:\sap2000-api\csharp\HelloSAP2000
dotnet run -c Release
```

SAP2000 opens (`Visible = true`), builds and analyses the cantilever
model, prints the base reaction, and exits.

## Cross-reference

- [docs/11-etabs-and-spacegass.md](../../docs/11-etabs-and-spacegass.md) —
  full CSi ETABS + SAP2000 + SpaceGass reference.
- [../etabs-api/](../etabs-api/) — the working sample this doc
  refers to.
