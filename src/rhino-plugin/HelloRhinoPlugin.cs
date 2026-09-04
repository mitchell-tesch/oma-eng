using System;
using Rhino;
using Rhino.PlugIns;

namespace HelloRhino;

/// <summary>
/// The Rhino plugin entry point. There must be exactly one class deriving
/// from <see cref="PlugIn"/> per assembly. Rhino discovers it by reflection
/// and calls <see cref="OnLoad"/> once per session.
/// </summary>
public sealed class HelloRhinoPlugin : PlugIn
{
    public HelloRhinoPlugin()
    {
        Instance = this;
    }

    public static HelloRhinoPlugin? Instance { get; private set; }

    protected override LoadReturnCode OnLoad(ref string errorMessage)
    {
        RhinoApp.WriteLine("HelloRhino: plugin loaded from Omarchy virtiofs share.");
        return LoadReturnCode.Success;
    }
}
