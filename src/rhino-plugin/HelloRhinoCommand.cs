using System;
using Rhino;
using Rhino.Commands;
using Rhino.Geometry;

namespace HelloRhino;

/// <summary>
/// Registers the <c>_HelloRhino</c> command. Type it at the Rhino command
/// line to prove the whole edit-in-Omarchy / build-in-guest pipeline works.
///
/// Run Rhino's <c>_SystemInfo</c> command separately to confirm the
/// passed-through Nvidia GPU is the active OpenGL device.
/// </summary>
public sealed class HelloRhinoCommand : Command
{
    public HelloRhinoCommand()
    {
        Instance = this;
    }

    public static HelloRhinoCommand? Instance { get; private set; }

    public override string EnglishName => "HelloRhino";

    protected override Result RunCommand(RhinoDoc doc, RunMode mode)
    {
        RhinoApp.WriteLine("Hello from Rhino on Omarchy!");
        RhinoApp.WriteLine("  Rhino version : {0}", RhinoApp.Version);
        RhinoApp.WriteLine("  Build date    : {0}", RhinoApp.BuildDate);
        RhinoApp.WriteLine("  Run \"_SystemInfo\" to see the active OpenGL device.");

        var sphere = new Sphere(Point3d.Origin, 5.0);
        var id = doc.Objects.AddSphere(sphere);
        if (id == Guid.Empty)
        {
            RhinoApp.WriteLine("HelloRhino: failed to add sphere.");
            return Result.Failure;
        }

        doc.Views.Redraw();
        RhinoApp.WriteLine("HelloRhino: added a sphere at origin, id={0}.", id);
        return Result.Success;
    }
}
