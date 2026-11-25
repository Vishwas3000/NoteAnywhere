using Microsoft.Win32;

namespace NoteAnywhere.Platform;

/// Settings ▸ Open NoteAnywhere when Windows starts: a per-user Run entry that starts it in the notification area.
static class OpenAtLogin
{
    const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run", Name = "NoteAnywhere";

    public static void Apply(bool on)
    {
        using var run = Registry.CurrentUser.CreateSubKey(Key);
        if (on && Environment.ProcessPath is { } exe) run.SetValue(Name, $"\"{exe}\" --background");
        else run.DeleteValue(Name, throwOnMissingValue: false);
    }
}
