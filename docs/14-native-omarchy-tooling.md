# 14 — Native Omarchy tooling (open-source)

Not every structural-engineering workflow needs Windows. Two
categories of work run natively on Omarchy — often better than
their Windows-guest equivalents because they avoid the VM entirely:

- **BIM viewing and IFC scripting** — open, inspect, extract data
  from, and even edit IFC files without booting the guest.
- **Engineering calc notebooks** — Mathcad-style calculations with
  rendered maths, driven from a plain-text source that lives in Git.

Prefer these for any task that doesn't strictly need Revit's
parametric authoring model, Rhino's viewport, or a commercial FEA
solver. The VM stays off, host RAM and battery stay untouched, and
the source stays in your normal editor next to the C# / Python
plugin code from doc 08.

This doc is orthogonal to the guest-setup chain (docs 01–13) — read
it any time.

## BIM: BlenderBIM / Bonsai

**Bonsai** (formerly *BlenderBIM Add-on*, renamed mid-2024) is a
Blender add-on for reading, writing, and editing IFC natively.
Free, open-source, GPL v3. Homepage: <https://bonsaibim.org/>.

What it does:

- Open any `.ifc` file (IFC 2x3, IFC 4, IFC 4.3) and see the full
  model — geometry, materials, property sets, spatial hierarchy.
- Edit IFC directly. Change property values, restructure the
  spatial tree, add or remove elements, export back to IFC.
- Extract quantity takeoffs and property tables to CSV / JSON.
- Round-trip IFC with Revit, ArchiCAD, Tekla, and Vectorworks.
- Runs on the iGPU by default. If you want the Nvidia dGPU
  for a render session, either unbind vfio-pci temporarily
  (see doc 03) or use CPU rendering (Cycles is fine on modern
  Ryzen / Intel).

### Install

```bash
# From the AUR (packaged for Arch/Omarchy):
yay -S blender-bonsai

# Alternatively, install Blender from the official repos and add
# the Bonsai add-on manually:
sudo pacman -S --needed blender
# Then in Blender: Edit ▸ Preferences ▸ Add-ons ▸ Install ▸
# point at the bonsai .zip downloaded from bonsaibim.org
```

Bonsai also ships as a Flatpak bundle if you'd rather sandbox it —
see the *Install* page on bonsaibim.org.

### Verify

```bash
blender &
# In Blender:
#   Edit ▸ Preferences ▸ Add-ons ▸ enable "Bonsai" (Bonsai will
#   register a new "BIM" workspace and add tabs to the Properties
#   panel)
#   File ▸ New ▸ IFC Project — creates a fresh IFC document
#   File ▸ Open — pick any .ifc file (drag-and-drop also works)
```

The BIM workspace shows the same IFC spatial tree Revit does
(Project → Site → Building → Storey → Elements) and a property
inspector for the selected element.

## IFC scripting: IfcOpenShell

Bonsai's guts are `ifcopenshell` — a C++/Python library for
reading and writing IFC. Use it directly for automation without the
Blender GUI. Faster for batch work, and lets you keep IFC
processing inside your normal `~/src/oma-eng/` Python scripts.

### Install

```bash
python -m pip install --user ifcopenshell
```

### Example — extract every structural column to CSV

```python
"""dump_ifc_columns.py — list every column in an IFC file with its
GlobalId, name, section profile, and containing storey."""
import csv
import sys

import ifcopenshell
import ifcopenshell.util.element

model = ifcopenshell.open(sys.argv[1])

with open("columns.csv", "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["GlobalId", "Name", "Profile", "Storey"])
    for col in model.by_type("IfcColumn"):
        storey = ifcopenshell.util.element.get_container(col)
        col_type = ifcopenshell.util.element.get_type(col)
        w.writerow([
            col.GlobalId,
            col.Name or "",
            col_type.Name if col_type else "",
            storey.Name if storey else "",
        ])

print(f"Wrote columns.csv for {len(model.by_type('IfcColumn'))} columns.")
```

Run:

```bash
python dump_ifc_columns.py ~/oma-eng-inbox/project.ifc
```

Typical wall-clock: seconds for a several-thousand-element model.
Revit would take minutes to open the same file just to browse.

### When to use Bonsai vs Revit

- **Bonsai on Omarchy** — receive an IFC from an architect, inspect
  the model, extract quantities, script bulk modifications, produce
  a filtered IFC for handoff to a fabricator. All fast, all
  scriptable, no VM.
- **Revit in the guest (doc 12)** — authoring detailed families,
  working inside a live Autodesk Docs project, running
  Autodesk-specific analyses, publishing project deliverables.
  Anything that needs the Revit parametric family model.

Most structural offices end up with **both**: Revit as the
authoring source-of-truth for internal projects, Bonsai as the
"look at what the architect sent us" viewer plus the script host
for QTO and IFC hygiene.

## Engineering calc notebooks: Jupyter + Handcalcs

Best open-source Mathcad alternative for structural hand-calcs.
Renders Python calculations as LaTeX equations with substituted
values — the exact Mathcad output shape, but the source is plain
`.ipynb` (JSON) or `.py` files, so it lives in Git and diffs
line-by-line.

- **JupyterLab** — the notebook UI
- **handcalcs** by Connor Ferster — the equation-rendering library
  (<https://github.com/connorferster/handcalcs>)
- **forallpeople** — unit-aware quantities (mm, MPa, kN, kN·m)
  that render inside the LaTeX output

### Install

Primary (uv — fast resolve, no venv activation dance; install with
`sudo pacman -S uv`):

```bash
uv pip install --user jupyterlab handcalcs forallpeople
```

Fallback (system pip):

```bash
python -m pip install --user jupyterlab handcalcs forallpeople
```

### Example — plastic-moment capacity of a beam

Create a fresh notebook with `jupyter lab`, then in a cell:

```python
%load_ext handcalcs.render
import forallpeople as si
si.environment("structural", top_level=True)
```

Then in the next cell (with a `%%render` magic at the top):

```python
%%render

# Steel plastic moment capacity, AS 4100 / EN 1993 style
f_y = 355 * MPa                    # yield stress, grade 355 steel
Z_x = 1_500_000 * mm**3            # plastic section modulus
gamma_M0 = 1.10                    # partial safety factor

M_p = f_y * Z_x                    # nominal plastic moment
phi_M_p = M_p / gamma_M0           # design moment capacity
```

Rendered in Jupyter as (paraphrased):

```
f_y      = 355 MPa
Z_x      = 1,500,000 mm³
gamma_M0 = 1.10

M_p      = f_y · Z_x = 355 MPa · 1,500,000 mm³ = 532.5 kN·m
phi_M_p  = M_p / gamma_M0 = 532.5 kN·m / 1.10 = 484.1 kN·m
```

Both the symbolic form and the numeric substitution are shown, and
the result carries units — same shape a hand-written calc would
have on a checked-and-signed pad.

### Sharing calcs with reviewers

- **HTML export** (`File ▸ Save and Export Notebook As ▸ HTML`) —
  read-only, no dependencies for the reviewer. Round-trips through
  email attachments cleanly.
- **PDF via LaTeX** for a signed calc package
  (`jupyter nbconvert --to pdf beam_calcs.ipynb`; needs a working
  `xelatex` — `sudo pacman -S texlive-most`).
- **Git commit** the `.ipynb` alongside the rest of your source.
  Diffs are per-cell. Add `jupytext` as a paired-format converter if
  you'd rather commit `.py` and generate the notebook on demand.

### When to use Jupyter vs Excel

- **Jupyter + Handcalcs** — repetitive parametric calcs, calcs
  that need to be checked and signed off, anything you'd version
  in Git next to a plugin's source.
- **Excel** — data tables, dashboards, load matrices, connection
  schedules, anything with dense tabular presentation.

The Rhino ↔ Excel and Strand7 ↔ Excel samples (doc 10) still need
Excel in the guest. But the calc-package half of a typical
structural report can live entirely on Omarchy.

## Numeric tooling — Octave, NumPy, SciPy, SymPy

For MATLAB-style numeric or symbolic work, no VM needed:

| Tool | Install | Use case |
|---|---|---|
| **GNU Octave** | `sudo pacman -S octave` | Runs most MATLAB scripts. Fine for one-off numeric work. |
| **NumPy / SciPy** | `pip install numpy scipy` | Faster than Octave for anything vectorised; the standard Python numeric stack. |
| **SymPy** | `pip install sympy` | Symbolic maths — closed-form derivations that complement Handcalcs. |
| **matplotlib** | `pip install matplotlib` | Publication-quality plotting, pairs with Jupyter. |

## Non-goals for this doc

- Replicating Revit's parametric family model in Bonsai. Bonsai
  handles IFC, which is a superset of what Revit exports — but
  authoring Revit-quality families needs Revit itself.
- Replacing ETABS / SAP2000 / Strand7 / SpaceGass with open-source
  FEA. **FEniCS**, **CalculiX**, and **Code_Aster** exist and are
  excellent, but none of them are drop-in replacements for a
  code-compliant structural check. Structural engineers still need
  a commercial solver for signed deliverables. See the vendor docs
  in the guest chain (docs 07 / 11).

## Exit criteria

- Bonsai add-on loads in Blender on Omarchy; opening a sample IFC
  shows a 3D model with a populated spatial tree in the BIM
  workspace.
- `python -c "import ifcopenshell; print(ifcopenshell.version)"`
  prints a version.
- `jupyter lab` launches, `%load_ext handcalcs.render` succeeds,
  and a `%%render` cell substituting values into a formula produces
  rendered LaTeX in the notebook output.

Back to [README](../README.md).
