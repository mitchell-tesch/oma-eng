using System;
using Rhino;
using Rhino.PlugIns;

namespace RhinoToExcel;

/// <summary>
/// Plugin entry point. Registers the <c>_RhinoToExcel</c> command that
/// exports the current document's object metadata to a new Excel
/// workbook via late-bound COM automation.
/// </summary>
public sealed class RhinoToExcelPlugin : PlugIn
{
    public RhinoToExcelPlugin()
    {
        Instance = this;
    }

    public static RhinoToExcelPlugin? Instance { get; private set; }

    protected override LoadReturnCode OnLoad(ref string errorMessage)
    {
        RhinoApp.WriteLine("RhinoToExcel: plugin loaded. Run _RhinoToExcel to export.");
        return LoadReturnCode.Success;
    }
}
