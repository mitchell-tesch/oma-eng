"""dump_ifc_columns.py — extract every column from an IFC file to CSV.

Usage:
    uv run python samples/dump_ifc_columns.py path/to/model.ifc [out.csv]

For each ``IfcColumn`` the row records GlobalId, Name, section profile
(via type IfcColumnType.Name if defined), and containing spatial
storey. Runs on Omarchy — no Windows guest, no CAD app.
"""
from __future__ import annotations

import csv
import sys
from pathlib import Path

import ifcopenshell
import ifcopenshell.util.element


def dump(ifc_path: Path, csv_path: Path) -> int:
    model = ifcopenshell.open(str(ifc_path))
    columns = model.by_type("IfcColumn")

    with csv_path.open("w", newline="", encoding="utf-8") as fp:
        w = csv.writer(fp)
        w.writerow(["GlobalId", "Name", "Profile", "Storey"])
        for col in columns:
            storey = ifcopenshell.util.element.get_container(col)
            col_type = ifcopenshell.util.element.get_type(col)
            w.writerow(
                [
                    col.GlobalId,
                    col.Name or "",
                    (col_type.Name if col_type else ""),
                    (storey.Name if storey else ""),
                ]
            )

    return len(columns)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: dump_ifc_columns.py <model.ifc> [columns.csv]", file=sys.stderr)
        return 2
    ifc_path = Path(argv[1])
    csv_path = Path(argv[2]) if len(argv) > 2 else Path("columns.csv")
    n = dump(ifc_path, csv_path)
    print(f"Wrote {csv_path} for {n} IfcColumn instances from {ifc_path.name}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
