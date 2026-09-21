"""hello_excel.py — smallest xlwings smoke test.

Opens a new Excel workbook via COM, writes a couple of cells, and prints
Excel's PID so you can cross-check with `nvidia-smi` or Task Manager.
Confirms three things at once:

  * xlwings is installed and resolvable in the current env,
  * Excel is installed and activated in the guest,
  * COM automation Python -> Excel works (per-Windows-session).

Run from an interactive PowerShell in the guest (Looking Glass or VS
Code Remote-SSH), not a plain `ssh windows-cad` session — COM needs a
user session.

    uv sync
    uv run hello_excel.py

Excel is left visible so you can inspect A1:A2. Close it manually.
"""

from __future__ import annotations

import sys

import xlwings as xw


def main() -> int:
    wb = xw.Book()
    sheet = wb.sheets[0]
    sheet.range("A1").value = "Hello from Omarchy via xlwings"
    sheet.range("A2").value = "COM automation Python -> Excel."
    print(f"Wrote A1:A2. Excel PID: {wb.app.pid} (see the visible workbook).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
