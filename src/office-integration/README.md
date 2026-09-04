# src/office-integration

Working samples that drive Excel from your Rhino and Strand7
automation, running inside the VFIO Windows guest documented in the
rest of this repo. Written to be edited on Omarchy and built/run in
the guest — see [docs/08-api-development.md](../../docs/08-api-development.md)
for the full workflow.

## Contents

| Path | What it does | Language | Runs where |
|---|---|---|---|
| [`python/strand7_to_excel.py`](python/strand7_to_excel.py) | Runs a Strand7 linear-static solve, pulls node reactions, writes them to a new Excel workbook with a formatted results table. | Python 3 + `xlwings` + `St7API.dll` | Windows guest |
| [`csharp/RhinoToExcel/`](csharp/RhinoToExcel/) | Registers `_RhinoToExcel` command in Rhino 8. Dumps GUID / layer / object type / area / volume / bounding box of the current document's objects into a new Excel workbook. | C# / .NET 7 / RhinoCommon + late-bound Excel COM | Windows guest |

## Prerequisites (guest side)

- Microsoft Excel installed and activated (365 or Office 2021+
  recommended; see [docs/10-office-integration.md](../../docs/10-office-integration.md) §
  *Installing Office in the VFIO guest*).
- For the Python sample: `py -m pip install --user xlwings`.
- For the C# sample: nothing beyond what
  [`src/rhino-plugin/`](../rhino-plugin/) needs — it uses late-bound
  COM so there's no Interop assembly to install.

## Why late-bound COM in C#?

The plugin uses `Type.GetTypeFromProgID("Excel.Application")` and
`dynamic` rather than referencing `Microsoft.Office.Interop.Excel`.
Two reasons:

1. Interop assemblies are version-locked to a specific Office release.
   Late binding works against whatever Excel is installed in the
   guest — 2019, 2021, 2024, 365 — without a rebuild.
2. It removes a NuGet dependency from the sample. Fewer moving parts
   when someone else clones this repo six months from now.

The trade-off is no compile-time checking of Excel API names. For a
sample this is fine; for large plugins consider generating an interop
assembly with `TlbImp` against the actual Excel install.
