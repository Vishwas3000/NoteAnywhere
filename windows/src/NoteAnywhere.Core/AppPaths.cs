namespace NoteAnywhere.Core;

/// Where NoteAnywhere keeps its files on this PC: %LOCALAPPDATA%\NoteAnywhere, or NOTEANYWHERE_DIR when set, which
/// tests and CI point at a scratch folder so they never touch real notes.
public static class AppPaths
{
    public static string Data { get; } = Environment.GetEnvironmentVariable("NOTEANYWHERE_DIR") is { Length: > 0 } dir
        ? dir
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NoteAnywhere");
}
