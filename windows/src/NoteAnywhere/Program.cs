using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Threading;
using NoteAnywhere.Core;
using NoteAnywhere.Platform;
using Velopack;

namespace NoteAnywhere;

/// One program in three roles, as on the Mac (docs/ARCHITECTURE.md): browsers start it as their native messaging host,
/// AI apps as an MCP server (--mcp), and otherwise it's the app. The role is picked here, before WPF starts.
static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        // The installer's hooks (install, update, uninstall) arrive as arguments and end here; anything else goes on.
        VelopackApp.Build().Run();
        if (args is ["--report-front", var file, var seconds]) return ReportFront(file, int.Parse(seconds));
        AppDomain.CurrentDomain.UnhandledException += (_, e) => CrashLog.Write(e.ExceptionObject);
        if (args is ["--mcp", ..]) return McpServer.Run();
        var app = new App();
        app.DispatcherUnhandledException += (_, e) => CrashLog.Write(e.Exception);
        app.InitializeComponent();
        return app.Run();
    }

    /// Test mode for CI: writes each place that comes to the front as a line of JSON, for `seconds` seconds.
    static int ReportFront(string file, int seconds)
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        using var front = new FrontWindow();
        void Write(FrontContext c) => File.AppendAllText(file, JsonSerializer.Serialize(c) + "\n");
        if (front.Current is { } now) Write(now);
        front.Changed += Write;
        new DispatcherTimer(TimeSpan.FromSeconds(seconds), DispatcherPriority.Normal, (_, _) => app.Shutdown(), app.Dispatcher).Start();
        return app.Run();
    }
}
