"""
strand7_to_excel.py — end-to-end sample: run a Strand7 solve and push
its node reactions into a formatted Excel workbook via xlwings.

Runs inside the VFIO Windows guest (see docs/03-vm-provisioning.md).

Workflow:
    1. Initialise St7API.dll (see hello_strand7.py for the API basics).
    2. Open a model file — defaults to the first .ST7 found in the
       Strand7 Samples directory (typically TESTOGL.ST7 or similar);
       override with STRAND7_MODEL env var.
    3. Run the linear-static solver.
    4. Read node reactions for every restrained node.
    5. Open Excel via xlwings, write a formatted results table with
       headers, autofit, and a summary total row.
    6. Save the workbook alongside the model file.

Prerequisites:
    py -m pip install --user xlwings
    (Strand7 R3 installed; Excel installed and activated in the guest.)
"""

from __future__ import annotations

import ctypes
import os
import sys
from ctypes import (
    POINTER,
    byref,
    c_char_p,
    c_double,
    c_long,
    create_string_buffer,
)
from pathlib import Path

# --- Strand7 API binding ---------------------------------------------------

STRAND7_DIR = Path(
    os.environ.get("STRAND7_DIR", r"C:\Program Files\Strand7 R31\Bin64")
)
DLL_PATH = STRAND7_DIR / "St7API.dll"
if not DLL_PATH.exists():
    sys.exit(f"St7API.dll not found at {DLL_PATH}. Set STRAND7_DIR env var.")

st7 = ctypes.WinDLL(str(DLL_PATH))


def _bind(name, argtypes, restype=c_long):
    fn = getattr(st7, name)
    fn.argtypes = argtypes
    fn.restype = restype
    return fn


St7Init             = _bind("St7Init", [])
St7Release          = _bind("St7Release", [])
St7OpenFile         = _bind("St7OpenFile", [c_long, c_char_p, c_char_p])
St7CloseFile        = _bind("St7CloseFile", [c_long])
St7RunSolver        = _bind("St7RunSolver", [c_long, c_long, c_long, c_long])
St7GetTotal         = _bind("St7GetTotal", [c_long, c_long, POINTER(c_long)])
St7OpenResultFile   = _bind("St7OpenResultFile",
                            [c_long, c_char_p, c_char_p, c_long,
                             POINTER(c_long), POINTER(c_long)])
St7CloseResultFile  = _bind("St7CloseResultFile", [c_long])
St7GetNodeResult    = _bind("St7GetNodeResult",
                            [c_long, c_long, c_long, c_long, POINTER(c_double)])
St7GetAPIErrorString = _bind("St7GetAPIErrorString",
                             [c_long, c_char_p, c_long])


def check(err, ctx):
    if err == 0:
        return
    buf = create_string_buffer(256)
    St7GetAPIErrorString(err, buf, 256)
    raise RuntimeError(f"{ctx}: [{err}] {buf.value.decode('ascii', 'ignore')}")


# --- Constants (from the Strand7 R3 API Reference) -------------------------

STRAND7_UID = 1
tyNODE      = 1                  # entity type: node

# Solver types
stLinearStatic = 1

# Solver run modes (4-value enum, NOT a boolean pair)
smNormalRun      = 1             # solver window visible, stays open
smProgressRun    = 2             # visible with progress bar
smBackgroundRun  = 3             # headless — use with API automation
smNormalCloseRun = 4             # visible, auto-closes when done

# Wait flag and Combination-code flags for OpenResultFile
btFalse = 0
btTrue  = 1
kNoCombinations          = 0
kGenerateNewCombinations = 1
kUseExistingCombinations = 2

# Node result-set types (rtNodeReact = 5; rtNodeVel = 2 — do not confuse)
rtNodeDisp  = 1
rtNodeReact = 5


# --- Excel writer ----------------------------------------------------------

def write_to_excel(rows, out_path, model_name):
    """Push a list of (node, Fx, Fy, Fz, Mx, My, Mz) tuples to Excel."""
    try:
        import xlwings as xw
    except ImportError:
        sys.exit(
            "xlwings not installed. Run:  py -m pip install --user xlwings"
        )

    app = xw.App(visible=True, add_book=False)
    try:
        wb = app.books.add()
        sheet = wb.sheets[0]
        sheet.name = "Reactions"

        # Title
        sheet.range("A1").value = f"Strand7 reactions — {model_name}"
        sheet.range("A1").font.bold = True
        sheet.range("A1").font.size = 14
        sheet.range("A1:G1").merge()

        # Header row
        headers = ["Node", "Fx (N)", "Fy (N)", "Fz (N)",
                   "Mx (N·m)", "My (N·m)", "Mz (N·m)"]
        sheet.range("A3").value = headers
        header_range = sheet.range("A3:G3")
        header_range.font.bold = True
        header_range.color = (200, 220, 240)

        # Data
        if rows:
            sheet.range("A4").value = rows
        else:
            sheet.range("A4").value = "(no restrained nodes returned reactions)"

        # Totals
        last_data_row = 3 + max(1, len(rows))
        total_row = last_data_row + 1
        sheet.range(f"A{total_row}").value = "TOTAL"
        for col_idx, col_letter in enumerate("BCDEFG", start=2):
            if rows:
                sheet.range(f"{col_letter}{total_row}").formula = \
                    f"=SUM({col_letter}4:{col_letter}{last_data_row})"
        sheet.range(f"A{total_row}:G{total_row}").font.bold = True
        sheet.range(f"A{total_row}:G{total_row}").color = (240, 240, 240)

        # Format numbers, autofit columns
        if rows:
            sheet.range(f"B4:G{total_row}").number_format = "0.00"
        sheet.range("A:G").autofit()

        wb.save(str(out_path))
        print(f"Excel workbook written: {out_path}")
        print("Excel left open so you can review; close the workbook when done.")
    finally:
        pass  # keep the app open with the workbook visible


# --- Main ------------------------------------------------------------------

def default_model_path():
    """Strand7 ships samples under bin/../Samples. Prefer the shipped
    TESTOGL.ST7 (documented), then any other .ST7 in Samples/, then
    hard fail. Override with STRAND7_MODEL to point at your own file."""
    override = os.environ.get("STRAND7_MODEL")
    if override:
        return Path(override)
    samples_dir = STRAND7_DIR.parent / "Samples"
    preferred_names = [
        "TESTOGL.ST7",
        "LSA-Beam.ST7",
        "Beam.ST7",
        "Truss.ST7",
    ]
    for name in preferred_names:
        candidate = samples_dir / name
        if candidate.exists():
            return candidate
    # Fall back: any .ST7 file we can find in Samples/.
    if samples_dir.is_dir():
        any_st7 = sorted(samples_dir.glob("*.ST7"))
        if any_st7:
            return any_st7[0]
    sys.exit(
        "Could not find a Strand7 sample model. Set STRAND7_MODEL env var "
        f"to an existing .ST7 file. Looked in: {samples_dir}"
    )


def run():
    model_path = default_model_path()
    scratch_dir = Path(r"C:\Users\Public\Strand7-scratch")
    scratch_dir.mkdir(parents=True, exist_ok=True)

    print(f"Strand7 DLL   : {DLL_PATH}")
    print(f"Opening model : {model_path}")

    check(St7Init(), "St7Init")
    try:
        check(
            St7OpenFile(
                STRAND7_UID,
                str(model_path).encode("ascii"),
                str(scratch_dir).encode("ascii"),
            ),
            "St7OpenFile",
        )

        # Solve
        err = St7RunSolver(
            STRAND7_UID, stLinearStatic, smNormalRun, btTrue
        )
        if err != 0:
            buf = create_string_buffer(256)
            St7GetAPIErrorString(err, buf, 256)
            print(f"Solver returned non-zero: [{err}] "
                  f"{buf.value.decode('ascii','ignore')}")
            print("Continuing anyway — result file may still be usable.")

        # Open the result file that the solver just produced. The 3rd arg
        # is a spectral-results file path (empty for LSA); the 4th arg is
        # a combination code — 1 = kGenerateNewCombinations.
        result_path = model_path.with_suffix(".LSA")
        num_primary = c_long()
        num_secondary = c_long()
        check(
            St7OpenResultFile(
                STRAND7_UID,
                str(result_path).encode("ascii"),
                b"",
                kGenerateNewCombinations,
                byref(num_primary),
                byref(num_secondary),
            ),
            "St7OpenResultFile",
        )

        # Enumerate nodes and read reactions
        num_nodes = c_long()
        check(St7GetTotal(STRAND7_UID, tyNODE, byref(num_nodes)),
              "St7GetTotal(nodes)")

        rows = []
        result_case = 1                     # first load case
        buf = (c_double * 6)()
        for node in range(1, num_nodes.value + 1):
            err = St7GetNodeResult(
                STRAND7_UID, rtNodeReact, node, result_case, buf
            )
            if err != 0:
                continue                    # unrestrained node, or no result
            fx, fy, fz, mx, my, mz = tuple(buf)
            magnitude = (fx * fx + fy * fy + fz * fz +
                         mx * mx + my * my + mz * mz)
            if magnitude < 1e-12:
                continue                    # skip zero reactions (unrestrained)
            rows.append((node, fx, fy, fz, mx, my, mz))

        print(f"Reactions collected from {len(rows)} restrained node(s).")

        St7CloseResultFile(STRAND7_UID)
        St7CloseFile(STRAND7_UID)
    finally:
        St7Release()

    out_xlsx = model_path.with_suffix(".reactions.xlsx")
    write_to_excel(rows, out_xlsx, model_path.stem)


if __name__ == "__main__":
    run()
