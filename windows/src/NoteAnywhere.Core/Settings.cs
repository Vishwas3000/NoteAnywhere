using System.Text.Json;
using System.Text.Json.Serialization;

namespace NoteAnywhere.Core;

/// Settings ▸ General, in settings.json beside the notes: the app and the browser host are separate processes and both
/// read it, as UserDefaults serves both on the Mac. A missing or unreadable file means the defaults.
public sealed record Settings
{
    /// "system" (Automatic), "light" or "dark" (D85).
    public string Appearance { get; init; } = "system";
    /// Off: the panel and the browser panel open only with their shortcut (D63).
    public bool OpenNotesByThemselves { get; init; } = true;
    /// "" = the region's; else a pattern such as "dd/MM/yyyy" (DateStyle on the Mac).
    public string DateFormat { get; init; } = "";
    /// Start with Windows, in the notification area, so the panel can follow the window in front.
    public bool OpenAtLogin { get; init; } = true;

    static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    static string File => Path.Combine(AppPaths.Data, "settings.json");

    public static Settings Load()
    {
        try { return JsonSerializer.Deserialize<Settings>(System.IO.File.ReadAllText(File), Json) ?? new(); }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return new(); }
    }

    public void Save()
    {
        Directory.CreateDirectory(AppPaths.Data);
        var temp = File + ".tmp";  // write then replace, so the host never reads half a file
        System.IO.File.WriteAllText(temp, JsonSerializer.Serialize(this, Json));
        System.IO.File.Move(temp, File, overwrite: true);
    }
}
