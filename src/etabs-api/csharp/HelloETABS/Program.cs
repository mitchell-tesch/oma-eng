// Program.cs — minimal ETABS OAPI sample.
//
// CSi-recommended pattern for ETABS 22+ / SAP2000 v25+: reference
// `ETABSv1.dll` (managed wrapper shipped inside the ETABS install)
// and drive the API via
// `new Helper().CreateObjectProgID("CSI.ETABS.API.ETABSObject")`.
// The Helper auto-discovers the newest ETABS install via the ProgID's
// LocalServer32 registration and launches ETABS.exe as a subprocess,
// returning a cOAPI reference — sidesteps `CO_E_SERVER_EXEC_FAILURE
// (0x80080005)` that hits the raw COM class factory path
// (`Type.GetTypeFromProgID` + `Activator.CreateInstance`) on newer
// Windows / ETABS releases when running unelevated. Introduced in
// ETABS 2016 v16.1 as a cleaner replacement for CreateObject(exePath).
// See the CSi API manual, cHelper.CreateObjectProgID.
//
// Everything below uses the strong interface types `cHelper`, `cOAPI`,
// `cSapModel` etc. from `ETABSv1.dll`. `dynamic` does NOT work here
// because CSi's co-classes implement the interface methods explicitly
// — `ApplicationStart`, `SapModel`, `CreateObject` etc. are invisible
// as public members of the concrete class and can only be reached via
// the interface. `dynamic` dispatch goes through public-member lookup,
// so it fails; the interface types don't.
//
// Build depends on `ETABSv1.dll` being at the `ETABSInstallDir` path
// declared in the csproj (default: `C:\Program Files\Computers and
// Structures\ETABS 23`). Override with
//     dotnet build -p:ETABSInstallDir="C:\...\ETABS 22"
// for other point releases. `ETABSv1.dll` is copied into
// `bin\*\net8.0-windows\` next to `HelloETABS.exe` so it resolves at
// runtime without touching the CSi install directory. Runtime only
// needs the ProgID registration (any ETABS install provides it).
//
// Enum values are cast from int literals so the sample stays portable
// across the small enum-member-name drift CSi occasionally introduces
// between point releases. If you retarget to an older ETABS (v19/v20)
// or SAP2000, cross-check each signature against the shipped
// `API\CSiAPIv1.chm` help file inside the install — CSi occasionally
// adds an argument at the tail of a method between major versions.
//
// What it does:
//   1. Launches a fresh ETABS instance via `Helper.CreateObjectProgID`.
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
// Prereq: ETABS 22 or 23 installed and licensed in the guest.
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
using ETABSv1;

namespace HelloETABS;

internal static class Program
{
    private static int Main()
    {
        // Helper launches ETABS.exe as a subprocess and returns a cOAPI
        // reference. Bypasses CO_E_SERVER_EXEC_FAILURE from the raw
        // class factory path (see top-of-file comment).
        cOAPI etabs = CreateETABS();

        try
        {
            // Strong-typed calls through the cOAPI / cSapModel interfaces.
            // Enum values cast from int keep the sample independent of
            // small ETABSv1 enum-member-name drift across point releases.
            // 3 == eUnits.kip_in_F. 1 == eLoadPatternType.Dead.
            // 0 == eItemType.Objects / eItemTypeElm.ObjectElm.
            Check(etabs.ApplicationStart(), "ApplicationStart");
            cSapModel sap = etabs.SapModel;

            Check(sap.InitializeNewModel((eUnits)3), "InitializeNewModel(kip_in_F)");
            Check(sap.File.NewBlank(), "File.NewBlank");

            // --- Joints -------------------------------------------------
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
            string frameName = "";
            Check(sap.FrameObj.AddByPoint(basePt, topPt, ref frameName,
                                          "Default", ""),
                  "FrameObj.AddByPoint");
            Console.WriteLine($"Frame added: '{frameName}'");

            // --- Restraint: fully fixed base ----------------------------
            bool[] fixedAll = { true, true, true, true, true, true };
            Check(sap.PointObj.SetRestraint(basePt, ref fixedAll, (eItemType)0),
                  "PointObj.SetRestraint");

            // --- Load pattern + point load ------------------------------
            // ETABS auto-creates 'DEAD' and 'LIVE' patterns on
            // File.NewBlank(); add under a different name to avoid a
            // rc=1 (name-already-exists) rejection from LoadPatterns.Add.
            Check(sap.LoadPatterns.Add("HELLO_DEAD", (eLoadPatternType)1, 0.0, true),
                  "LoadPatterns.Add(HELLO_DEAD)");

            // Apply 10 kip horizontal load at the top joint in +X.
            double[] force = { 10.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
            Check(sap.PointObj.SetLoadForce(topPt, "HELLO_DEAD", ref force,
                                            false, "Global", (eItemType)0),
                  "PointObj.SetLoadForce");

            // --- Analyse ------------------------------------------------
            // ETABS RunAnalysis requires the model saved to disk first.
            var modelPath = @"C:\Users\Public\HelloETABS_scratch.edb";
            Check(sap.File.Save(modelPath), "File.Save");
            Check(sap.Analyze.RunAnalysis(), "Analyze.RunAnalysis");
            Console.WriteLine("Analysis complete.");

            // --- Extract reaction at base --------------------------------
            Check(sap.Results.Setup.DeselectAllCasesAndCombosForOutput(),
                  "Results.Setup.DeselectAll...");
            Check(sap.Results.Setup.SetCaseSelectedForOutput("HELLO_DEAD", true),
                  "Results.Setup.SetCaseSelectedForOutput(HELLO_DEAD)");

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
                    basePt, (eItemTypeElm)0,
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
        }

        return 0;
    }

    private static cOAPI CreateETABS()
    {
        // CreateObjectProgID auto-discovers the newest ETABS install via
        // the ProgID's LocalServer32 registration and launches it as a
        // subprocess. Preferred over CreateObject(exePath) since v16.1 —
        // no hardcoded path, no ETABS-version pinning at runtime.
        // Reference: CSi API manual, cHelper.CreateObjectProgID.
        const string ProgID = "CSI.ETABS.API.ETABSObject";

        cHelper helper = new Helper();
        cOAPI etabs = helper.CreateObjectProgID(ProgID);
        Console.WriteLine($"ETABS launched via Helper.CreateObjectProgID(\"{ProgID}\").");
        return etabs;
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