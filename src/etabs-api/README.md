# src/etabs-api

Samples for driving **CSi ETABS 22** via its OAPI (Open API).

## Contents

| Path | What it is | Approach |
|---|---|---|
| [`csharp/HelloETABS/`](csharp/HelloETABS/) | Console app that starts ETABS, builds a cantilever column model, runs LSA, prints base reaction. | Late-bound COM via `dynamic` + `GetTypeFromProgID("CSI.ETABS.API.ETABSObject")` |

## Why late-bound COM?

The alternative — referencing `ETABSv1.dll` from the ETABS install
directory via `<Reference HintPath="...">` — pins the sample to a
specific ETABS build path. Late-bound `dynamic` works against any
installed ETABS v19+ without a rebuild, at the cost of no
compile-time method checking. For samples this is the right trade-off.

For production plugins where compile-time safety matters, switch to
a hard reference against `ETABSv1.dll` and regenerate against each
target ETABS build.

## Prereqs

- ETABS 22 installed and licensed in the guest.
- COM component registered — the ETABS installer does this by default.
  Confirm from an admin PowerShell:
  ```powershell
  Get-ChildItem "HKLM:\SOFTWARE\Classes\CSI.ETABS.API.ETABSObject"
  ```

## Run

```powershell
cd Z:\src\oma-eng\src\etabs-api\csharp\HelloETABS
dotnet run -c Release
```

ETABS opens (Visible=true), builds and analyses the tiny model, prints
the base reaction, and exits.

## Extend

Once this runs, look at CSi's OAPI documentation for the full method
surface. The pattern (`Check(sap.SubInterface.Method(...))`) scales to
any operation ETABS exposes: `LoadCases`, `Analyze`, `Results.*`,
`Design*`, `View`, `File.Save`, etc.

Cross-reference: [docs/11-etabs-and-spacegass.md](../../docs/11-etabs-and-spacegass.md).