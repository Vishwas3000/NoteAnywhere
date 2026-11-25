using System.Windows.Threading;
using Velopack;
using Velopack.Sources;

namespace NoteAnywhere;

/// New versions from the GitHub releases, as Sparkle on the Mac: a check a minute after start, then daily. A new
/// version downloads quietly and installs the next time the app starts (Velopack applies it on startup), or at once
/// from the tray's Restart to Update. Each architecture is its own channel (win-x64, win-arm64), so both share a release.
static class Updates
{
    // NOTEANYWHERE_UPDATES (a folder or web address of releases) stands in for GitHub, so CI can update an installed copy.
    static readonly UpdateManager Manager = System.Environment.GetEnvironmentVariable("NOTEANYWHERE_UPDATES") is { Length: > 0 } feed
        ? new UpdateManager(feed)
        : new UpdateManager(new GithubSource("https://github.com/Vishwas3000/NoteAnywhere", null, false));
    static readonly DispatcherTimer Timer = new() { Interval = TimeSpan.FromMinutes(1) };

    /// A new version is downloaded and ready: its number.
    public static event Action<string>? Ready;

    public static void Start()
    {
        if (!Manager.IsInstalled) return;  // run from a build folder (CI, development): nothing to update
        Timer.Tick += async (_, _) =>
        {
            Timer.Interval = TimeSpan.FromDays(1);
            await Check();
        };
        Timer.Start();
    }

    static async Task Check()
    {
        try
        {
            if (Manager.UpdatePendingRestart is { } pending) { Ready?.Invoke(pending.Version.ToString()); return; }
            if (await Manager.CheckForUpdatesAsync() is not { } update) return;
            await Manager.DownloadUpdatesAsync(update);
            Ready?.Invoke(update.TargetFullRelease.Version.ToString());
        }
        catch (Exception e) { CrashLog.Write(e); }  // offline, GitHub's rate limit…: tomorrow's check tries again
    }

    /// --update-now (CI): check, download and restart into the new version straight away.
    public static async Task NowAndRestart()
    {
        await Check();
        RestartNow();
    }

    public static void RestartNow()
    {
        if (Manager.UpdatePendingRestart is { } pending) Manager.ApplyUpdatesAndRestart(pending);
    }
}
