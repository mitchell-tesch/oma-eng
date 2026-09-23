# 14 — Native Omarchy tooling (open-source)

Not every structural-engineering workflow needs Windows. Two
categories of work run natively on Omarchy — often better than
their Windows-guest equivalents because they avoid the VM entirely:

- **BIM viewing and IFC scripting** — open, inspect, extract data
  from, and even edit IFC files without booting the guest. Two
  viewers are covered: FreeCAD (light, pacman-installable) and
  Bonsai/Blender (heavier, full IFC authoring).
- **Engineering calc notebooks** — Mathcad-style calculations with
  rendered maths, driven from a plain-text source that lives in Git.

Prefer these for any task that doesn't strictly need Revit's
parametric authoring model, Rhino's viewport, or a commercial FEA
solver. The VM stays off, host RAM and battery stay untouched, and
the source stays in your normal editor next to the C# / Python
plugin code from [doc 08](08-api-development.md).

This doc is orthogonal to the guest-setup chain (docs 01–13) — read
it any time.

Companion project: [`src/native-tooling/`](../src/native-tooling/README.md).
It ships an `uv`-managed venv with every dependency below already
pinned, plus a smoke-test IFC and a handcalcs notebook you can
execute in one command.

## GPU on the host — what you have

While the guest is running, the Nvidia RTX A500 is bound to
`vfio-pci` and invisible to Omarchy. The host desktop and every
process on it — Blender included — runs on the **Intel Arc iGPU**
(`i915` driver, Meteor Lake). That's plenty for:

- Bonsai / Blender viewport for IFC model inspection and light
  edits.
- IFC scripting via `ifcopenshell` (CPU-only anyway).
- Cycles renders using **CPU** or **oneAPI** (Intel Arc) backend.
- JupyterLab in the browser, matplotlib plots, numpy/scipy work.

If you need the dGPU on the host (Cycles OptiX, ML training), shut
the guest down first and unbind `vfio-pci` — the doc 03 §"Handing
the GPU back to Linux" section covers it.

```bash
# Verify iGPU is what Blender sees:
lspci -nnk | grep -A2 -iE "VGA|3D"
# Kernel driver in use: i915                     ← iGPU, live
# Kernel driver in use: vfio-pci                 ← dGPU, held for guest
```

## BIM: Bonsai (Blender add-on)

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

### Install Blender — which version?

Blender ships two flavours on Omarchy:

| Purpose | Where | Blender | Python |
|---|---|---|---|
| General 3D / Cycles rendering / anything **not** Bonsai | `sudo pacman -S blender` | 5.2 LTS | 3.14 |
| **Bonsai / IFC authoring** | Blender 4.5 LTS portable from blender.org | 4.5.4 LTS | 3.11 |

**Why two.** As of this doc, the Bonsai release on
extensions.blender.org is `v0.8.5-post1`, declared
`blender_version_max=5.1.0`, built against Python 3.13. Blender 5.2
ships with Python 3.14 and refuses to load the extension
(`Extension bl_ext.blender_org.bonsai is incompatible`). Upstream
Bonsai typically catches up 2–4 weeks after a new Blender LTS —
switch back to the system Blender once a compatible release lands.

```bash
# General-purpose Blender (repo):
sudo pacman -S --needed blender

# Bonsai-compatible Blender (portable to ~/tools/, no root):
mkdir -p ~/tools && cd ~/tools
curl -fsSLO https://download.blender.org/release/Blender4.5/blender-4.5.4-linux-x64.tar.xz
tar xf blender-4.5.4-linux-x64.tar.xz

# Launcher shim so the LTS+Bonsai combo is on PATH as `blender-bim`:
cat > ~/.local/bin/blender-bim <<'SH'
#!/usr/bin/env bash
exec "$HOME/tools/blender-4.5.4-linux-x64/blender" --online-mode "$@"
SH
chmod +x ~/.local/bin/blender-bim
blender-bim --version   # Blender 4.5.4 LTS
```

### Install the Bonsai add-on

Upstream ships Bonsai through the official Blender extensions
repo. Blender exposes a CLI installer so you can enable it
without the GUI:

```bash
blender-bim --command extension sync
blender-bim --command extension install --enable bonsai
```

GUI equivalent, if you prefer clicking:

1. `blender-bim &`
2. *Edit ▸ Preferences ▸ Get Extensions*
3. Search **Bonsai** → *Install*
4. *Edit ▸ Preferences ▸ Add-ons* → tick **Bonsai** to enable
5. Bonsai adds a **BIM** workspace tab across the top of Blender

> The AUR alternative `yay -S ifcopenshell` (0.9.0-alpha) builds
> from source against system Python 3.14 and bundles Bonsai. Heavy
> source build (boost, cgal, opencascade). Only bother if the
> upstream Blender extension is dragging its feet and you also
> want the C++ `ifcopenshell` CLI system-wide. Do **not** `yay -S
> bonsai` — the top hit is an unrelated web browser.

### Verify

Interactive:

```bash
cd ~/dev/oma-eng/src/native-tooling
uv sync                     # first time only
blender-bim samples/smoke.ifc
# In Blender:
#   Switch to the BIM workspace tab (added by Bonsai)
#   The IFC spatial tree (Project → Site → Building → Storey)
#   shows Ground with two IfcColumn objects.
```

Headless smoke test (proves the addon loads and Bonsai's
`load_project` operator works, without opening a window):

```bash
blender-bim --background --python-expr "
import bpy, ifcopenshell
bpy.ops.bim.load_project(filepath='/home/mzt/dev/oma-eng/src/native-tooling/samples/smoke.ifc')
m = ifcopenshell.open(bpy.context.scene.BIMProperties.ifc_file)
print('Columns in loaded model:', len(m.by_type('IfcColumn')))
"
# Import finished in 0.13 seconds
# Columns in loaded model: 2
```

## IFC scripting: IfcOpenShell

Bonsai's guts are `ifcopenshell` — a C++/Python library for
reading and writing IFC. Use it directly for automation without the
Blender GUI. Faster for batch work, and lets you keep IFC
processing inside your normal `~/dev/oma-eng/` Python scripts.

### Install (uv, project-local)

The `src/native-tooling/` project already lists `ifcopenshell` in
its `pyproject.toml`:

```bash
cd ~/dev/oma-eng/src/native-tooling
uv sync                                     # once
uv run python -c "import ifcopenshell; print(ifcopenshell.version)"
# 0.8.5 (or newer)
```

### One-off use outside a project

Modern Python is PEP 668 "externally managed" — plain
`pip install --user` will refuse. Two clean options:

```bash
# 1. ephemeral uv environment (no venv activation, no state):
uv run --with ifcopenshell python -c "import ifcopenshell; print(ifcopenshell.version)"

# 2. install as a user tool (only for scripts with entry points):
uv tool install ifcopenshell
```

### Example — extract every structural column to CSV

`src/native-tooling/samples/dump_ifc_columns.py` is a ready-to-run
example. The essential shape:

```python
"""dump_ifc_columns.py — list every column in an IFC file with its
GlobalId, name, section profile, and containing storey."""
import csv, sys
import ifcopenshell
import ifcopenshell.util.element

model = ifcopenshell.open(sys.argv[1])
with open(sys.argv[2], "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["GlobalId", "Name", "Profile", "Storey"])
    for col in model.by_type("IfcColumn"):
        storey   = ifcopenshell.util.element.get_container(col)
        col_type = ifcopenshell.util.element.get_type(col)
        w.writerow([
            col.GlobalId,
            col.Name or "",
            col_type.Name if col_type else "",
            storey.Name  if storey   else "",
        ])
```

Run:

```bash
cd ~/dev/oma-eng/src/native-tooling
uv run python samples/dump_ifc_columns.py samples/smoke.ifc /tmp/cols.csv
cat /tmp/cols.csv
# GlobalId,Name,Profile,Storey
# 2ur20wQHTDFwhm8X5JpvtO,C-01,,Ground
# 1dExm_cjf2lwj7tchr2XRH,C-02,,Ground
```

Typical wall-clock: seconds for a several-thousand-element model.
Revit would take minutes to open the same file just to browse.

### When to use Bonsai vs Revit

- **Bonsai on Omarchy** — receive an IFC from an architect, inspect
  the model, extract quantities, script bulk modifications, produce
  a filtered IFC for handoff to a fabricator. All fast, all
  scriptable, no VM.
- **Revit in the guest ([doc 12](12-revit-and-rhino-inside.md))** —
  authoring detailed families, working inside a live Autodesk Docs
  project, running Autodesk-specific analyses, publishing project
  deliverables. Anything that needs the Revit parametric family
  model.

Most structural offices end up with **both**: Revit as the
authoring source-of-truth for internal projects, Bonsai as the
"look at what the architect sent us" viewer plus the script host
for QTO and IFC hygiene.

## BIM viewing: FreeCAD + NativeIFC

FreeCAD 1.1's built-in **BIM workbench** opens IFC through
**NativeIFC** — the model stays an IFC file on disk and FreeCAD
lazily builds shapes for whatever you expand in the tree. For
"the architect sent us an IFC, what's in it?" this is lighter
than Bonsai: no portable Blender, no Python-version juggling,
and it is a plain `pacman` package.

```bash
sudo pacman -S --needed freecad          # 1.1.3 at time of writing
freecad --version
```

FreeCAD on Arch links against **system Python 3.14**
(`ldd /usr/lib/freecad/lib/FreeCAD.so | grep python`). That matters
below — and it is why FreeCAD works where Bonsai doesn't:
`ifcopenshell` 0.8.4+ publishes `py314` manylinux wheels, whereas
Bonsai's Blender extension is still pinned to Python 3.13.

### Installing IfcOpenShell for FreeCAD — best practice

FreeCAD ships its own sandboxed vendor directory for extra Python
packages and puts it on `sys.path` at startup:

```
~/.local/share/FreeCAD/v1-1/AdditionalPythonPackages/py314
```

That is the **only** location you should install into. It is
per-user, per-FreeCAD-version, per-Python-version, and it is what
the BIM workbench's own updater targets.

**Recommended — let FreeCAD do it (GUI):**

1. Open FreeCAD, switch to the **BIM** workbench.
2. *Utils ▸ IfcOpenShell Update*.
3. FreeCAD reports *"No existing IfcOpenShell installation found"*
   and offers the newest release. Click **OK**.
4. Restart FreeCAD.

The dialog's own wording — *"the update is installed in your
FreeCAD's user directory and will not affect the rest of your
system"* — is exactly the property you want on an Arch box.

**Equivalent from the shell** (same command FreeCAD runs
internally, useful for scripting a fresh host):

```bash
VENDOR="$HOME/.local/share/FreeCAD/v1-1/AdditionalPythonPackages/py314"
mkdir -p "$VENDOR"
python3 -m pip install --upgrade --disable-pip-version-check \
        --target "$VENDOR" ifcopenshell
```

`--target` sidesteps PEP 668, so there is no
`externally-managed-environment` error and no
`--break-system-packages` anywhere. Needs `python-pip` installed
(`sudo pacman -S --needed python-pip`), which FreeCAD's updater
needs too.

> Derive the `v1-1` / `py314` parts rather than hardcoding them if
> you are scripting for several machines:
> `FreeCADCmd` → `import addonmanager_utilities as u;
> print(u.get_pip_target_directory())`.

### Why not the obvious alternatives

| Approach | Verdict |
|---|---|
| `pip install --user ifcopenshell` | Blocked by PEP 668; forcing it with `--break-system-packages` pollutes every Python 3.14 process on the host. |
| `sudo pip install` into `/usr/lib/python3.14/site-packages` | Pacman-managed directory. A `freecad`/`python` upgrade will fight you. Never do this on Arch. |
| `yay -S ifcopenshell` (AUR, 0.9.0-alpha) | Multi-hour source build (boost, CGAL, OpenCascade) against system Python, and an alpha. Only worth it if you also want the C++ CLI system-wide. |
| Reusing `src/native-tooling/.venv` | That venv is built by `uv` against its own interpreter and is not on FreeCAD's `sys.path`. Handy for scripting (below), useless to FreeCAD. |
| FreeCAD AppImage / Flatpak | Bundles its own Python and its own vendor dir — the pacman build plus the vendor directory is simpler here. |

### Verify

```bash
FreeCADCmd -c "import ifcopenshell; print(ifcopenshell.version)"
```

Headless end-to-end — loads an IFC through NativeIFC, expands the
spatial tree, and confirms real BRep geometry was built:

```bash
cat > /tmp/fc_ifc_check.py <<'PY'
import FreeCAD
from nativeifc import ifc_import, ifc_tools
doc = FreeCAD.newDocument("check")
ifc_import.insert("/path/to/model.ifc", doc.Name)
ifc_tools.create_children(doc.Objects[0], recursive=True)
doc.recompute()
for o in doc.Objects:
    shape = getattr(o, "Shape", None)
    print(o.Label, "|", getattr(o, "Class", "-"),
          "| verts:", len(shape.Vertexes) if shape else 0)
PY
FreeCADCmd /tmp/fc_ifc_check.py
# GeomTest  | IfcProject        | verts: 0
# Site      | IfcSite           | verts: 0
# Building  | IfcBuilding       | verts: 0
# Ground    | IfcBuildingStorey | verts: 0
# C1        | IfcColumn         | verts: 8
# C2        | IfcColumn         | verts: 8
```

Interactively, just `freecad model.ifc` — FreeCAD registers
NativeIFC as the `.ifc` handler, so the import dialog appears and
the project lands in the tree. Expand a node to make FreeCAD build
that element's shape on demand.

> `src/native-tooling/samples/smoke.ifc` is a *schema-only* fixture
> with no `IfcShapeRepresentation` entities — it loads, but FreeCAD
> logs `get_geom_iterator: Invalid iterator` and draws nothing.
> That is correct behaviour, not a broken install. Use a real
> architect-issued IFC to see geometry.

### Do not re-enable the legacy IFC importer

FreeCAD 1.1 still ships the pre-NativeIFC importer at
`importers/importIFC.py`, but it is **commented out** of
`Mod/BIM/Init.py` on purpose: it calls the IfcOpenShell **0.7**
geometry-settings API and dies on 0.8.x with

```
'Settings' object has no attribute 'USE_BREP_DATA'
```

Leave `addImportType` alone and stay on NativeIFC. See
[doc 09](09-troubleshooting.md#settings-object-has-no-attribute-use_brep_data).

### Keeping it current, and undoing it

```bash
# upgrade later (or use Utils ▸ IfcOpenShell Update again)
python3 -m pip install --upgrade --target "$VENDOR" ifcopenshell

# full clean removal — nothing outside this tree was touched
rm -rf "$HOME/.local/share/FreeCAD/v1-1/AdditionalPythonPackages"
```

### FreeCAD vs Bonsai vs the `ifcopenshell` scripts

| Task | Reach for |
|---|---|
| Quick look at an incoming IFC, measure something, check a level | **FreeCAD** — one pacman package, opens fast, lazy geometry |
| Serious IFC authoring/editing, drawing sheets, QTO UI | **Bonsai** — deeper IFC toolset, but needs the portable Blender 4.5 |
| Batch extraction, CI checks, anything repeatable | **`ifcopenshell` scripts** in `src/native-tooling/` (below) |
| FEA on the imported geometry | Export STEP from FreeCAD → Strand7 / ETABS in the guest |

## Engineering calc notebooks: Jupyter + Handcalcs

Best open-source Mathcad alternative for structural hand-calcs.
Renders Python calculations as LaTeX equations with substituted
values — the exact Mathcad output shape, but the source is plain
`.ipynb` (JSON) or paired `.py` files, so it lives in Git and diffs
line-by-line.

- **JupyterLab** — the notebook UI
- **handcalcs** by Connor Ferster — the equation-rendering library
  (<https://github.com/connorferster/handcalcs>)
- **forallpeople** — unit-aware quantities (mm, MPa, kN, kN·m)
  that render inside the LaTeX output
- **jupytext** — pair `.ipynb` with a `.py` (percent format) so Git
  diffs stay readable

### Install

Primary (uv, project-local — already pinned in
`src/native-tooling/pyproject.toml`):

```bash
cd ~/dev/oma-eng/src/native-tooling
uv sync                     # jupyterlab, handcalcs, forallpeople, jupytext
uv run jupyter lab          # browser opens JupyterLab
```

Or as a global user tool (no project needed):

```bash
sudo pacman -S --needed jupyterlab
uv tool install --with handcalcs --with forallpeople jupyter
jupyter lab
```

### VS Code alternative

The Jupyter extension (`ms-toolsai.jupyter`) opens `.ipynb` files
inside VS Code with the same kernel picker, cell-by-cell execution,
and rich output rendering. `src/native-tooling/.vscode/extensions.json`
already recommends it. Point VS Code at the `.venv/` uv created and
Ctrl+Enter runs the current cell.

### Example — plastic-moment capacity of a beam

Full source in [`src/native-tooling/samples/beam_capacity.py`](../src/native-tooling/samples/beam_capacity.py)
(jupytext percent format) with an executed
[`beam_capacity.ipynb`](../src/native-tooling/samples/beam_capacity.ipynb)
snapshot alongside. The essential cells:

```python
%load_ext handcalcs.render
import forallpeople as si
si.environment("structural", top_level=True)
```

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

Execute end-to-end from the shell to prove the stack works:

```bash
cd ~/dev/oma-eng/src/native-tooling
uv run jupyter nbconvert --to notebook --execute --inplace \
    samples/beam_capacity.ipynb
# → M_p = 532.500 kN·m, phi_M_p ≈ 484.091 kN·m
```

### Sharing calcs with reviewers

- **HTML export** (`File ▸ Save and Export Notebook As ▸ HTML`) —
  read-only, no dependencies for the reviewer. Round-trips through
  email attachments cleanly.
- **PDF via XeLaTeX + pandoc** for a signed calc package:

  ```bash
  sudo pacman -S --needed pandoc-cli \
      texlive-basic texlive-latexextra texlive-latexrecommended \
      texlive-fontsextra texlive-fontsrecommended texlive-xetex \
      texlive-binextra texlive-plaingeneric texlive-mathscience
  uv run jupyter nbconvert --to pdf samples/beam_capacity.ipynb
  ```

  On modern Arch/Omarchy the `texlive-most` group no longer exists
  — install the specific `texlive-*` packages above. `nbconvert`
  pipes through `pandoc` and then `xelatex`; missing either one
  produces cryptic *"Pandoc wasn't found"* or *"File `soul.sty'
  not found"* errors. `texlive-plaingeneric` supplies `soul.sty`
  and `texlive-mathscience` supplies `bm.sty`, both of which the
  default nbconvert template pulls in.
- **Git commit** the `.py` (jupytext percent format) as the
  source-of-truth, optionally also commit the executed `.ipynb`.
  jupytext round-trips both:

  ```bash
  # from .py to executable notebook
  uv run jupytext --to ipynb samples/beam_capacity.py
  # from executed notebook back to reviewable .py
  uv run jupytext --to py:percent samples/beam_capacity.ipynb
  ```

### When to use Jupyter vs Excel

- **Jupyter + Handcalcs** — repetitive parametric calcs, calcs
  that need to be checked and signed off, anything you'd version
  in Git next to a plugin's source.
- **Excel** — data tables, dashboards, load matrices, connection
  schedules, anything with dense tabular presentation.

The Rhino ↔ Excel and Strand7 ↔ Excel samples ([doc 10](10-office-integration.md))
still need Excel in the guest. But the calc-package half of a
typical structural report can live entirely on Omarchy.

## Numeric tooling — Octave, NumPy, SciPy, SymPy

For MATLAB-style numeric or symbolic work, no VM needed. NumPy /
SciPy / SymPy / matplotlib are all in `src/native-tooling/`'s
`pyproject.toml` already.

| Tool | Install | Use case |
|---|---|---|
| **GNU Octave** | `sudo pacman -S octave` | Runs most MATLAB scripts. Fine for one-off numeric work. |
| **NumPy / SciPy** | `uv sync` (already listed) | Faster than Octave for anything vectorised; the standard Python numeric stack. |
| **SymPy** | `uv sync` (already listed) | Symbolic maths — closed-form derivations that complement Handcalcs. |
| **matplotlib** | `uv sync` (already listed) | Publication-quality plotting, pairs with Jupyter. |

## Non-goals for this doc

- Replicating Revit's parametric family model in Bonsai. Bonsai
  handles IFC, which is a superset of what Revit exports — but
  authoring Revit-quality families needs Revit itself.
- Replacing ETABS / SAP2000 / Strand7 / SpaceGass with open-source
  FEA. **FEniCS**, **CalculiX**, and **Code_Aster** exist and are
  excellent, but none of them are drop-in replacements for a
  code-compliant structural check. Structural engineers still need
  a commercial solver for signed deliverables. See the vendor docs
  in the guest chain ([07](07-strand7-setup.md) / [11](11-etabs-and-spacegass.md)).

## Exit criteria

- `FreeCADCmd -c "import ifcopenshell; print(ifcopenshell.version)"`
  prints `0.8.5` or newer, resolved from
  `~/.local/share/FreeCAD/v1-1/AdditionalPythonPackages/py314/`.
- `freecad some-model.ifc` opens the project in the tree and
  expanding an element builds its shape.
- `blender-bim --version` prints *Blender 4.5.4 LTS*.
- The Bonsai add-on loads: opening
  `src/native-tooling/samples/smoke.ifc` in `blender-bim` shows the
  spatial tree in the BIM workspace, or the headless test

  ```bash
  blender-bim --background --python-expr "
  import bpy; bpy.ops.bim.load_project(filepath='$PWD/samples/smoke.ifc');
  print('OK')"
  ```

  prints `OK` and reports 2 columns.
- `uv run python samples/dump_ifc_columns.py samples/smoke.ifc /tmp/cols.csv`
  writes a two-row CSV.
- `uv run jupyter nbconvert --to notebook --execute --inplace samples/beam_capacity.ipynb`
  completes without error, and the executed notebook contains a
  rendered LaTeX cell showing `M_p = 532.500 kN·m`.
- `uv run jupyter nbconvert --to pdf samples/beam_capacity.ipynb`
  writes `samples/beam_capacity.pdf` (needs `pandoc-cli` +
  `texlive-plaingeneric` + `texlive-mathscience` on top of the
  earlier texlive install).

Back to [README](../README.md).
