using System.Runtime.InteropServices;
using Rhino.PlugIns;

// The plugin GUID must be stable across builds — Rhino uses it to
// key per-plugin settings, licence grants, and its registered-plugins
// list. Do not regenerate this value; if you fork this sample as a
// starting point for your own plugin, replace it with a fresh
// `uuidgen` output once and then leave it alone.
[assembly: Guid("a003083d-64c2-4eba-8073-b304e386f433")]

[assembly: PlugInDescription(DescriptionType.Organization, "oma-eng")]
[assembly: PlugInDescription(DescriptionType.WebSite,      "https://github.com/mitchell-tesch/oma-eng")]
