using System;
using System.Collections.Generic;
using System.Linq;
using Rhino;
using Rhino.Commands;
using Rhino.DocObjects;
using Rhino.Geometry;

namespace RhinoToExcel;

/// <summary>
/// Registers the <c>_RhinoToExcel</c> command. Exports metadata for the
/// currently selected objects (or all document objects if nothing is
/// selected) to a new Excel workbook via late-bound COM.
///
/// Columns: Id, Name, Layer, Type, Area, Volume, BBox min/max XYZ.
///
/// Late-bound COM is used deliberately so the plugin builds and runs
/// against any installed Excel version (2019, 2021, 2024, 365) without
/// pinning an Interop assembly. See src/office-integration/README.md.
/// </summary>
public sealed class RhinoToExcelCommand : Command
{
    public RhinoToExcelCommand() { Instance = this; }
    public static RhinoToExcelCommand? Instance { get; private set; }

    public override string EnglishName => "RhinoToExcel";

    protected override Result RunCommand(RhinoDoc doc, RunMode mode)
    {
        var objects = doc.Objects.GetSelectedObjects(false, false).ToList();
        if (objects.Count == 0)
        {
            objects = doc.Objects
                .Where(o => o.IsValid && o.Visible && !o.IsLocked)
                .ToList();
            RhinoApp.WriteLine($"RhinoToExcel: nothing selected; exporting all {objects.Count} visible unlocked objects.");
        }
        else
        {
            RhinoApp.WriteLine($"RhinoToExcel: exporting {objects.Count} selected objects.");
        }

        if (objects.Count == 0)
        {
            RhinoApp.WriteLine("RhinoToExcel: document is empty. Nothing to export.");
            return Result.Nothing;
        }

        var rows = objects.Select(o => RowFor(o, doc)).ToList();

        try
        {
            WriteToExcel(rows, System.IO.Path.GetFileNameWithoutExtension(doc.Path ?? "untitled"));
        }
        catch (System.Runtime.InteropServices.COMException ex)
        {
            RhinoApp.WriteLine($"RhinoToExcel: Excel COM failure — {ex.Message}");
            RhinoApp.WriteLine("Check that Microsoft Excel is installed and activated in this VM.");
            return Result.Failure;
        }

        return Result.Success;
    }

    private static ObjectRow RowFor(RhinoObject o, RhinoDoc doc)
    {
        var layer = doc.Layers.FindIndex(o.Attributes.LayerIndex);
        var bbox  = o.Geometry?.GetBoundingBox(true) ?? BoundingBox.Empty;

        double area   = double.NaN;
        double volume = double.NaN;

        switch (o.Geometry)
        {
            case Brep brep:
                area   = brep.GetArea();
                if (brep.IsSolid) volume = brep.GetVolume();
                break;
            case Mesh mesh:
                area   = AreaMassProperties.Compute(mesh)?.Area   ?? double.NaN;
                if (mesh.IsClosed)
                    volume = VolumeMassProperties.Compute(mesh)?.Volume ?? double.NaN;
                break;
            case Extrusion ex when ex.ToBrep() is Brep exb:
                area = exb.GetArea();
                if (exb.IsSolid) volume = exb.GetVolume();
                break;
            case Surface srf:
                area = AreaMassProperties.Compute(srf)?.Area ?? double.NaN;
                break;
        }

        return new ObjectRow(
            o.Id.ToString(),
            o.Attributes.Name ?? string.Empty,
            layer?.Name ?? string.Empty,
            o.ObjectType.ToString(),
            area, volume,
            bbox.Min.X, bbox.Min.Y, bbox.Min.Z,
            bbox.Max.X, bbox.Max.Y, bbox.Max.Z);
    }

    private static void WriteToExcel(IReadOnlyList<ObjectRow> rows, string modelName)
    {
        var excelType = Type.GetTypeFromProgID("Excel.Application")
            ?? throw new InvalidOperationException(
                "Excel is not registered as a COM server. Install Excel in this VM.");

        dynamic excel = Activator.CreateInstance(excelType)!;
        excel.Visible = true;
        excel.DisplayAlerts = false;

        try
        {
            dynamic wb    = excel.Workbooks.Add();
            dynamic sheet = wb.Worksheets[1];
            sheet.Name = "Rhino objects";

            sheet.Range["A1"].Value = $"Rhino → Excel: {modelName}";
            sheet.Range["A1"].Font.Bold = true;
            sheet.Range["A1"].Font.Size = 14;
            sheet.Range["A1:L1"].Merge();

            var headers = new object[]
            {
                "Id", "Name", "Layer", "Type",
                "Area", "Volume",
                "BBox min X", "BBox min Y", "BBox min Z",
                "BBox max X", "BBox max Y", "BBox max Z",
            };
            dynamic headerRow = sheet.Range["A3:L3"];
            headerRow.Value = headers;
            headerRow.Font.Bold = true;
            headerRow.Interior.Color = 0xF0DCC8;   // OLE BGR = RGB(200,220,240) pale blue

            var data = new object[rows.Count, 12];
            for (int i = 0; i < rows.Count; i++)
            {
                var r = rows[i];
                data[i, 0]  = r.Id;
                data[i, 1]  = r.Name;
                data[i, 2]  = r.Layer;
                data[i, 3]  = r.Type;
                data[i, 4]  = double.IsNaN(r.Area)   ? (object)"" : r.Area;
                data[i, 5]  = double.IsNaN(r.Volume) ? (object)"" : r.Volume;
                data[i, 6]  = r.MinX;
                data[i, 7]  = r.MinY;
                data[i, 8]  = r.MinZ;
                data[i, 9]  = r.MaxX;
                data[i, 10] = r.MaxY;
                data[i, 11] = r.MaxZ;
            }
            dynamic dataRange = sheet.Range[
                sheet.Cells[4, 1],
                sheet.Cells[3 + rows.Count, 12]];
            dataRange.Value = data;

            // Number formats
            sheet.Range[
                sheet.Cells[4, 5],
                sheet.Cells[3 + rows.Count, 12]].NumberFormat = "0.00";

            // Autofit
            sheet.Columns.AutoFit();

            // Freeze headers
            excel.ActiveWindow.SplitRow = 3;
            excel.ActiveWindow.FreezePanes = true;

            RhinoApp.WriteLine($"RhinoToExcel: wrote {rows.Count} row(s). Save the workbook from Excel when you're done.");
        }
        finally
        {
            excel.DisplayAlerts = true;
            // Deliberately do NOT quit Excel — leave the workbook visible
            // so the user can review and save it.
        }
    }

    private readonly record struct ObjectRow(
        string Id,
        string Name,
        string Layer,
        string Type,
        double Area,
        double Volume,
        double MinX, double MinY, double MinZ,
        double MaxX, double MaxY, double MaxZ);
}
