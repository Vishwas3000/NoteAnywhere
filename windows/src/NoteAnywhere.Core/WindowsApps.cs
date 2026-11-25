namespace NoteAnywhere.Core;

/// An app's id in note targets. For apps on both systems it's the Mac's bundle id, so a note made in Slack on one
/// computer shows in the same Slack chat on the other once sync is on (D86); any other program is "win.<exe name>".
public static class WindowsApps
{
    // shortcut: a hand-made list of programs whose Mac bundle id is known; add apps as they come up.
    static readonly Dictionary<string, string> MacIds = new(StringComparer.OrdinalIgnoreCase)
    {
        ["slack"] = "com.tinyspeck.slackmacgap",
        ["code"] = "com.microsoft.VSCode",
        ["chrome"] = "com.google.Chrome",
        ["msedge"] = "com.microsoft.edgemac",
        ["brave"] = "com.brave.Browser",
        ["whatsapp"] = "net.whatsapp.WhatsApp",
        ["discord"] = "com.hnc.Discord",
        ["ms-teams"] = "com.microsoft.teams2",
        ["notion"] = "notion.id",
        ["obsidian"] = "md.obsidian",
        ["figma"] = "com.figma.Desktop",
        ["zoom"] = "us.zoom.xos",
        ["spotify"] = "com.spotify.client",
    };

    /// `exeName` without ".exe": "slack", "Code", "notepad".
    public static string Id(string exeName) =>
        MacIds.TryGetValue(exeName, out var id) ? id : "win." + exeName.ToLowerInvariant();
}
