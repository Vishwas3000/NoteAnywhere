namespace NoteAnywhere;

static class AppInfo
{
    /// "0.1.4", from the repo's VERSION file (Directory.Build.props).
    public static string Version { get; } = typeof(AppInfo).Assembly.GetName().Version?.ToString(3) ?? "dev";
    /// What feedback says it was sent with, as the Mac's "NoteAnywhere 0.1.4, macOS 26.2".
    public static string About { get; } = $"NoteAnywhere {Version}, Windows {Environment.OSVersion.Version}";
}
