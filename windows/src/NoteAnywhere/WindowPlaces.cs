using System.IO;
using System.Text.Json;
using System.Windows;
using NoteAnywhere.Core;

namespace NoteAnywhere;

/// Windows open where they were last left, as macOS restores them: each window's bounds by name in windows.json beside
/// the notes, saved whenever it hides (closing only hides; quitting closes).
static class WindowPlaces
{
    static string File => Path.Combine(AppPaths.Data, "windows.json");

    /// Puts the window back where it was, if that's still on a screen; false when the caller should place it.
    public static bool Restore(Window window, string name)
    {
        window.IsVisibleChanged += (_, _) => { if (!window.IsVisible) Save(name, window.RestoreBounds); };
        if (!Load().TryGetValue(name, out var b) || b.Length != 4 || !OnScreen(new Rect(b[0], b[1], b[2], b[3]))) return false;
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        (window.Left, window.Top, window.Width, window.Height) = (b[0], b[1], b[2], b[3]);
        return true;
    }

    // shortcut: tests against the box around all screens, so a corner between two unequal monitors passes; fine unless
    // someone reports a window opening out of sight.
    static bool OnScreen(Rect r)
    {
        var all = new Rect(SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenTop,
                           SystemParameters.VirtualScreenWidth, SystemParameters.VirtualScreenHeight);
        return r.Width >= 100 && r.Height >= 100 && r.Top >= all.Top && r.Top < all.Bottom - 40
            && r.Right > all.Left + 80 && r.Left < all.Right - 80;  // the title bar can be reached
    }

    static Dictionary<string, double[]> Load()
    {
        try { return JsonSerializer.Deserialize<Dictionary<string, double[]>>(System.IO.File.ReadAllText(File)) ?? []; }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return []; }
    }

    static void Save(string name, Rect r)
    {
        if (r.IsEmpty) return;  // never shown
        var all = Load();
        all[name] = [r.X, r.Y, r.Width, r.Height];
        try
        {
            Directory.CreateDirectory(AppPaths.Data);
            System.IO.File.WriteAllText(File, JsonSerializer.Serialize(all));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }  // unsaved, it just opens in the default place
    }
}
