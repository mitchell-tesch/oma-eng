using System.Runtime.InteropServices;
using Rhino.PlugIns;

// The plugin GUID must be stable across builds — Rhino uses it to
// key per-plugin settings, licence grants, and its registered-plugins
// list. Do not regenerate this value; if you fork this sample as a
// starting point for your own plugin, replace it with a fresh
// `uuidgen` output once and then leave it alone.
[assembly: Guid("1a681a8d-9b1d-4595-a957-10359b99c0e6")]

[assembly: PlugInDescription(DescriptionType.Organization, "rhino-omarchy")]
[assembly: PlugInDescription(DescriptionType.WebSite,      "https://github.com/mitchell-tesch/rhino-omarchy")]
