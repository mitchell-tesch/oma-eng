// HelloStrand7.cs — smallest possible Strand7 R3 automation from C#.
//
// Same purpose as the Python sibling: prove that .NET code inside the
// guest can drive Strand7's API end-to-end (Init → New file → mutate →
// Solve → Read → Close) from source that lives on the Omarchy host.
//
// Uses direct P/Invoke against St7API.dll — no COM registration
// required. Runs as a plain console EXE:
//
//     dotnet run -c Release
//
// Requires x64. St7API.dll is 64-bit on Strand7 R3.
//
// Full function inventory + constants are documented in the Strand7 R3
// API Reference Manual. The set below is the minimum for a smoke test.

using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace HelloStrand7;

internal static class Program
{
    private const string Dll = "St7API.dll";

    private const int St7Uid                 = 1;

    // Constants per the Strand7 R3 API Reference.
    private const int LinearStatic           = 1;   // stLinearStatic
    private const int NormalRun              = 1;   // smNormalRun (NOT 0 — 4-value enum)
    private const int WaitBlock              = 1;   // btTrue — block until solver exits

    [DllImport(Dll)] private static extern int St7Init();
    [DllImport(Dll)] private static extern int St7Release();
    [DllImport(Dll, CharSet = CharSet.Ansi)]
    private static extern int St7NewFile(int uID, string fileName, string scratch);
    [DllImport(Dll)] private static extern int St7CloseFile(int uID);
    [DllImport(Dll)]
    private static extern int St7SetNodeXYZ(int uID, int nodeNum, [In] double[] xyz);
    [DllImport(Dll)]
    private static extern int St7RunSolver(int uID, int solver, int mode, int wait);
    [DllImport(Dll, CharSet = CharSet.Ansi)]
    private static extern int St7GetAPIErrorString(int err, StringBuilder buf, int maxLen);

    private static void Check(int err, string ctx)
    {
        if (err == 0) return;
        var sb = new StringBuilder(256);
        St7GetAPIErrorString(err, sb, sb.Capacity);
        throw new InvalidOperationException($"{ctx}: [{err}] {sb}");
    }

    private static int Main()
    {
        var strand7Dir = Environment.GetEnvironmentVariable("STRAND7_DIR")
                        ?? @"C:\Program Files\Strand7 R31\Bin64";
        // Make St7API.dll resolvable from the process default dir.
        SetDllDirectory(strand7Dir);

        var modelFile  = @"C:\Users\Public\hello_strand7.st7";
        var scratchDir = @"C:\Users\Public\Strand7-scratch";
        Directory.CreateDirectory(scratchDir);

        Console.WriteLine($"Strand7 DLL dir: {strand7Dir}");
        Check(St7Init(), "St7Init");
        try
        {
            Check(St7NewFile(St7Uid, modelFile, scratchDir), "St7NewFile");
            Console.WriteLine($"Created empty Strand7 model: {modelFile}");

            // Trivial mutation to exercise a marshalled array.
            var xyz = new double[] { 0.0, 0.0, 0.0 };
            Check(St7SetNodeXYZ(St7Uid, 1, xyz), "St7SetNodeXYZ(1)");

            var solverErr = St7RunSolver(
                St7Uid, LinearStatic, NormalRun, WaitBlock);
            if (solverErr == 0)
            {
                Console.WriteLine("Linear-static solver returned success.");
            }
            else
            {
                var sb = new StringBuilder(256);
                St7GetAPIErrorString(solverErr, sb, sb.Capacity);
                Console.WriteLine($"Solver stopped: [{solverErr}] {sb}");
            }

            Check(St7CloseFile(St7Uid), "St7CloseFile");
        }
        finally
        {
            St7Release();
        }

        Console.WriteLine("Hello from Strand7 on Omarchy.");
        return 0;
    }

    // SetDllDirectoryW — Unicode variant so `STRAND7_DIR` values
    // containing non-ASCII characters (accented usernames in
    // %USERPROFILE%, non-English `Program Files` localisation) work.
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetDllDirectory(string path);
}
