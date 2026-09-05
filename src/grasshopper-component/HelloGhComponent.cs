using System;
using Grasshopper.Kernel;
using Rhino.Geometry;

namespace HelloGh;

/// <summary>
/// Trivial Grasshopper component: takes a radius, outputs a sphere at the
/// origin. Its point is to prove the .gha build+load pipeline from Omarchy.
/// </summary>
public sealed class HelloGhComponent : GH_Component
{
    public HelloGhComponent()
        : base("Hello Omarchy",
               "OmarchySphere",
               "A minimal Grasshopper component built from the Omarchy virtiofs share.",
               "Params",
               "oma-eng")
    {
    }

    public override Guid ComponentGuid => new("8f9c1b12-1af1-4a4a-9b0f-1f3e5a0d6b7c");

    protected override void RegisterInputParams(GH_InputParamManager pm)
    {
        pm.AddNumberParameter("Radius", "R", "Sphere radius", GH_ParamAccess.item, 5.0);
    }

    protected override void RegisterOutputParams(GH_OutputParamManager pm)
    {
        pm.AddBrepParameter("Sphere", "S", "Sphere as a Brep at the world origin", GH_ParamAccess.item);
    }

    protected override void SolveInstance(IGH_DataAccess da)
    {
        double radius = 0.0;
        if (!da.GetData(0, ref radius)) return;
        if (radius <= 0.0)
        {
            AddRuntimeMessage(GH_RuntimeMessageLevel.Warning, "Radius must be > 0");
            return;
        }

        var brep = new Sphere(Point3d.Origin, radius).ToBrep();
        da.SetData(0, brep);
    }
}

/// <summary>
/// Grasshopper assembly info — visible in Grasshopper's <c>File ▸
/// Preferences ▸ Libraries</c>.
/// </summary>
public sealed class HelloGhInfo : GH_AssemblyInfo
{
    public override string Name        => "HelloGh (oma-eng)";
    public override Guid   Id           => new("39b1fb7d-3e07-4b3c-9df0-1c9e6e3b5f10");
    public override string AuthorName   => "oma-eng";
    public override string Description  => "Smallest possible Grasshopper 1 component.";
}
