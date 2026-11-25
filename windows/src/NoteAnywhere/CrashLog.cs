using System.IO;
using NoteAnywhere.Core;

namespace NoteAnywhere;

/// An unhandled error is written to crash.log beside the notes (and to the debug output) before the app goes, so a
/// crash on a PC nobody here can see, or on CI, can be read afterwards.
static class CrashLog
{
    public static string File => Path.Combine(AppPaths.Data, "crash.log");

    public static void Write(object? error)
    {
        try
        {
            Directory.CreateDirectory(AppPaths.Data);
            System.IO.File.AppendAllText(File, $"{DateTimeOffset.Now:O} NoteAnywhere {AppInfo.Version}\n{error}\n\n");
        }
        catch (IOException) { }
        System.Diagnostics.Trace.WriteLine($"NoteAnywhere crashed: {error}");
    }
}
