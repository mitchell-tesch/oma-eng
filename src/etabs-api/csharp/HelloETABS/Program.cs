// Program.cs — minimal ETABS 22 OAPI sample.
//
// Uses late-bound COM (dynamic + GetTypeFromProgID) so this compiles
// on Omarchy without ETABSv1.dll present and runs against any ETABS
// v19+ install in the guest — CSi keeps the OAPI shape stable across
// releases.
//
// Signature note: late-bound `dynamic` COM invocation does NOT honour
// the type-library default parameters that a `<Reference>`-linked
// interop assembly would fill in for you. Every OAPI call here passes
// its full argument list explicitly. If you retarget to an older
// ETABS (v19/v20) or SAP2000, cross-check each signature against
// the shipped `API\CSiAPIv1.chm` help file inside the install — CSi
// occasionally adds an argument at the tail of a method between
// major versions.
//
// What it does:
//   1. Launches a fresh ETABS instance via COM.
//   2. Creates a new blank steel-units model.
//   3. Adds two joints (base + top of a cantilever column).
//   4. Adds a frame element between them (default section).
//   5. Fully restrains the base joint.
//   6. Defines a DEAD load pattern and applies a horizontal point load
//      at the top joint.
//   7. Runs linear-static analysis.
//   8. Reads the base joint reaction and prints it.
//
// End-to-end reference — each layer of the API is exercised once so
// extending it into a real integration is a matter of adding calls.
//
// Prereq: ETABS 22 installed and licensed in the guest.
//
// Run:
//   cd Z:\etabs-api\csharp\HelloETABS
//   dotnet run -c Release
//
// The ETABS window opens (Visible = true), builds and analyses the
// model, then closes. The console prints the base joint reaction.
//
// Reference: CSi OAPI docs — Help > Documentation inside ETABS, and
// https://wiki.csiamerica.com/  (search "OAPI").

using System;
using System.Runtime.InteropServices;

namespace HelloETABS;

internal static class Program
{
    private const string ProgID = "CSI.ETABS.API.ETABSObject";

    private static int Main()
    {
        // .NET 5+ removed Marshal.GetActiveObject, so we always spin up a
        // fresh ETABS instance rather than attempting to attach to a
        // running one. Extending this to walk the running-object table
        // (IRunningObjectTable) is left as an exercise — real integrations
        // that need attach-semantics should do that walk here.
        dynamic etabs = CreateETABS();

        try
        {
            // ApplicationStart(eUnits, bool Visible, string FileName)
            // Explicit args because dynamic COM invocation does NOT
            // honour type-lib default parameters — every OAPI call in
            // this file has to pass the full argument list.
            // Units 3 == eUnits.kip_in_F.
            Check(etabs.ApplicationStart(3, true, ""), "ApplicationStart");
            dynamic sap = etabs.SapModel;

            // Units: kip_in_F = 3 in the eUnits enum. Value `1` is
            // lb_in_F (pounds), not kip — verified against CSi's OAPI
            // enum used across ETABSv1 / SAP2000v1.
            Check(sap.InitializeNewModel(3), "InitializeNewModel(kip_in_F)");
            Check(sap.File.NewBlank(), "File.NewBlank");

            // --- Joints -------------------------------------------------
            // PointObj.AddCartesian(X, Y, Z, ref Name, UserName, CSys,
            //                        MergeOff, MergeNumber)
            // 8 args required — the last three have IDL defaults that
            // late-bound COM ignores.
            string basePt = "";
            string topPt  = "";
            Check(sap.PointObj.AddCartesian(0.0, 0.0,   0.0, ref basePt,
                                            "", "Global", false, 0),
                  "AddCartesian(base)");
            Check(sap.PointObj.AddCartesian(0.0, 0.0, 144.0, ref topPt,
                                            "", "Global", false, 0),
                  "AddCartesian(top)");     // 144 in = 12 ft column

            Console.WriteLine($"Joints created: base='{basePt}', top='{topPt}'");

            // --- Frame element ------------------------------------------
            // FrameObj.AddByPoint(Point1, Point2, ref Name, PropName, UserName)
            // PropName "Default" uses the first available frame section.
            string frameName = "";
            Check(sap.FrameObj.AddByPoint(basePt, topPt, ref frameName,
                                          "Default", ""),
                  "FrameObj.AddByPoint");
            Console.WriteLine($"Frame added: '{frameName}'");

            // --- Restraint: fully fixed base ----------------------------
            // PointObj.SetRestraint(Name, ref bool[6], eItemType)
            // 6-boolean array: [Ux, Uy, Uz, Rx, Ry, Rz]
            // ItemType 0 == Objects (act on the named point only).
            bool[] fixedAll = { true, true, true, true, true, true };
            Check(sap.PointObj.SetRestraint(basePt, ref fixedAll, 0),
                  "PointObj.SetRestraint");

            // --- Load pattern + point load ------------------------------
            // LoadPatterns.Add(Name, eLoadPatternType, SelfWTMultiplier,
            //                   AddLoadCase)
            // type 1 == DEAD in CSi's eLoadPatternType.
            Check(sap.LoadPatterns.Add("DEAD", 1, 0.0, true),
                  "LoadPatterns.Add(DEAD)");

            // PointObj.SetLoadForce(Name, LoadPat, ref double[6],
            //                        Replace, CSys, eItemType)
            // Apply 10 kip horizontal load at the top joint in +X.
            double[] force = { 10.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
            Check(sap.PointObj.SetLoadForce(topPt, "DEAD", ref force,
                                            false, "Global", 0),
                  "PointObj.SetLoadForce");

            // --- Analyse ------------------------------------------------
            // ETABS's RunAnalysis requires the model to be saved to disk
            // at least once; the "modified but never saved" state is
            // rejected by the OAPI. Save to a scratch path first.
            var modelPath = @"C:\Users\Public\HelloETABS_scratch.edb";
            Check(sap.File.Save(modelPath), "File.Save");
            Check(sap.Analyze.RunAnalysis(), "Analyze.RunAnalysis");
            Console.WriteLine("Analysis complete.");

            // --- Extract reaction at base --------------------------------
            Check(sap.Results.Setup.DeselectAllCasesAndCombosForOutput(),
                  "Results.Setup.DeselectAll...");
            // SetCaseSelectedForOutput(Name, Selected) — the second arg
            // is required by the COM signature.
            Check(sap.Results.Setup.SetCaseSelectedForOutput("DEAD", true),
                  "Results.Setup.SetCaseSelectedForOutput(DEAD)");

            // JointReact populates arrays by ref. Sizes are set by the
            // API — we pass in placeholders. ItemTypeElm 0 = ObjectElm.
            int numResults = 0;
            string[] obj  = Array.Empty<string>();
            string[] elm  = Array.Empty<string>();
            string[] loadCase = Array.Empty<string>();
            string[] stepType = Array.Empty<string>();
            double[] stepNum  = Array.Empty<double>();
            double[] fx = Array.Empty<double>(), fy = Array.Empty<double>(),
                     fz = Array.Empty<double>();
            double[] mx = Array.Empty<double>(), my = Array.Empty<double>(),
                     mz = Array.Empty<double>();

            Check(sap.Results.JointReact(
                    basePt, 0,
                    ref numResults,
                    ref obj, ref elm, ref loadCase, ref stepType, ref stepNum,
                    ref fx, ref fy, ref fz, ref mx, ref my, ref mz),
                  "Results.JointReact");

            for (int i = 0; i < numResults; i++)
            {
                Console.WriteLine(
                    $"Reaction @ '{obj[i]}' case '{loadCase[i]}': "
                    + $"Fx={fx[i]:0.###} Fy={fy[i]:0.###} Fz={fz[i]:0.###}  "
                    + $"Mx={mx[i]:0.###} My={my[i]:0.###} Mz={mz[i]:0.###}");
            }

            Console.WriteLine("Hello from ETABS on Omarchy.");
        }
        finally
        {
            try { etabs.ApplicationExit(false); } catch { /* ignore */ }
            // After ApplicationExit the RCW is dead; ReleaseComObject
            // then throws InvalidComObjectException or 0x800706BA. Guard.
            try { Marshal.ReleaseComObject(etabs); } catch { /* ignore */ }
        }

        return 0;
    }

    private static dynamic CreateETABS()
    {
        Type? etabsType = Type.GetTypeFromProgID(ProgID);
        if (etabsType is null)
            throw new InvalidOperationException(
                $"ETABS COM ProgID '{ProgID}' not registered. "
                + "Confirm ETABS 20/21/22 is installed in this VM.");

        object? instance = Activator.CreateInstance(etabsType);
        if (instance is null)
            throw new InvalidOperationException("Failed to create ETABS COM object.");

        Console.WriteLine("ETABS instance created.");
        return instance;
    }

    /// <summary>
    /// CSi OAPI convention: every method returns 0 on success and a
    /// non-zero error code on failure. This wraps that pattern.
    /// </summary>
    private static void Check(int rc, string ctx)
    {
        if (rc != 0)
            throw new InvalidOperationException(
                $"OAPI call failed: {ctx} returned {rc}. "
                + "Check the ETABS log for details.");
    }
}