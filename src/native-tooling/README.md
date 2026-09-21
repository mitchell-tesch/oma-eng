# src/native-tooling — Omarchy-native structural tooling

Host-native scripts and calc notebooks that don't need the Windows
guest. Run on Omarchy directly (Wayland, iGPU, no VFIO involvement).

The Windows guest keeps Rhino, Strand7, ETABS, SAP2000, SpaceGass,
Revit, and Office. **This** project hosts everything that a
structural engineer can do without them: IFC reading/writing via
`ifcopenshell`, and calc-package generation via `handcalcs` +
`forallpeople` inside JupyterLab.

Full walkthrough in [../../docs/14-native-omarchy-tooling.md](../../docs/14-native-omarchy-tooling.md).

## What's here

| Path | What | Runtime |
|---|---|---|
| `pyproject.toml` / `uv.lock` | uv-managed venv for the whole project | `uv sync` |
| `samples/dump_ifc_columns.py` | Read an IFC, dump every `IfcColumn` to CSV | `uv run` |
| `samples/beam_capacity.py` | Steel plastic-moment capacity — handcalcs source, jupytext `# %%` percent format | `uv run` |
| `samples/beam_capacity.ipynb` | Executed snapshot of the above (open in JupyterLab or VS Code Jupyter) | JupyterLab |
| `samples/smoke.ifc` | Two-column synthetic IFC used by the dump-columns smoke test | — |

## First-time setup

```bash
cd ~/dev/oma-eng/src/native-tooling
uv sync                           # creates .venv/ with every dep pinned
```

## Smoke tests

```bash
# IFC extraction
uv run python samples/dump_ifc_columns.py samples/smoke.ifc /tmp/cols.csv
cat /tmp/cols.csv                 # 2 IfcColumn rows

# Handcalcs notebook — execute end-to-end
uv run jupyter nbconvert --to notebook --execute --inplace samples/beam_capacity.ipynb

# Or interactively:
uv run jupyter lab                # browser opens JupyterLab
#   Open samples/beam_capacity.ipynb, Run All Cells.
```

## Why this project exists

- The Windows guest costs 24 GiB of RAM and the whole VFIO dance.
  Skip it whenever the task doesn't need Revit / Rhino / a commercial
  solver.
- `ifcopenshell` reads the IFC that a Revit user in the guest just
  exported, and vice versa. Round-trip lives on the host.
- `handcalcs` + `forallpeople` produce Mathcad-shaped calcs from a
  Python source that lives in Git alongside the C# / Python plugin
  code (see [doc 08](../../docs/08-api-development.md)).
- Nvidia dGPU is bound to `vfio-pci` while the guest is up — Blender
  and any Python GPU compute on the host uses the Intel Arc iGPU or
  CPU. Fine for Bonsai model inspection, IFC QTOs, and CPU-side
  Cycles renders. If you need dGPU on the host, shut the guest down
  and unbind `vfio-pci` (see doc 03).
