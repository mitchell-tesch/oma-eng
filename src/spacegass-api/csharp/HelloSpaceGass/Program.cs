// Program.cs — smallest possible SPACE GASS 14.5+ automation from C#.
//
// Same shape as the Python sibling: connect to the REST API service,
// open the built-in Portal Frame.SG sample, list every node, close.
// Uses the official SpaceGassApi NuGet package (Kiota-generated
// against the vendor's OpenAPI schema at api.spacegass.com).
//
// Modelled on the vendor Quick Start sample at
// github.com/SpaceGass/space-gass-api/blob/main/sdks/csharp/examples/
// Example.QuickStart/Program.cs
//
// Prereqs (in the guest):
//   - SPACE GASS 14.5 or later, opened at least once
//   - `dotnet restore` (pulls SpaceGassApi from NuGet)
//   - SpaceGassApi.exe running (default http://localhost:34560)
//
// Run:
//   dotnet run
//   dotnet run -- http://192.168.122.42:34560   # optional: custom URL

using SpaceGassApi;
using SpaceGassApi.Models;

var baseUrl = args.Length > 0 ? args[0] : "http://localhost:34560";

var client = SpaceGassApiClient.CreateClient(baseUrl);

try
{
    Console.WriteLine($"Connecting to SPACE GASS API at {baseUrl}");
    Console.WriteLine("Opening built-in sample 'Portal Frame.SG'...");
    await client.Job.OpenSample.PostAsync(
        new OpenSampleRequest { FileName = "Portal Frame.SG" });

    var nodes = await client.Job.Structure.Nodes.GetAsync();
    Console.WriteLine($"Found {nodes!.Count} node(s):");
    foreach (var node in nodes)
    {
        Console.WriteLine($"  Node {node.Id}: ({node.X}, {node.Y}, {node.Z})");
    }

    Console.WriteLine("Hello from SPACE GASS on Omarchy.");
}
catch (ErrorResponse err)
{
    Console.ForegroundColor = ConsoleColor.Red;
    Console.Error.WriteLine($"API error {err.Status}: {err.Title}");
    if (!string.IsNullOrWhiteSpace(err.Detail))
        Console.Error.WriteLine($"  {err.Detail}");
    Console.ResetColor();
    return 1;
}
finally
{
    Console.WriteLine("Closing project...");
    await client.Job.Close.PostAsync();
}

return 0;
