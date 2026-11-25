using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Threading;
using NoteAnywhere.Core;
using NoteAnywhere.Core.Search;
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
        if (args is ["--write-title", var report]) return WriteTitle(report).GetAwaiter().GetResult();
        AppDomain.CurrentDomain.UnhandledException += (_, e) => CrashLog.Write(e.ExceptionObject);
        var app = new App();
        app.DispatcherUnhandledException += (_, e) => CrashLog.Write(e.Exception);
        app.InitializeComponent();
        return app.Run();
    }

    /// Test mode for CI: ✨ Title on a short note through Assistant.Run, as the editor runs it, twice (loading the model,
    /// then loaded). Downloads the writing model first when it isn't here, as Settings does once the person agrees. Search
    /// embeds the note before and after, as both models share ONNX Runtime in the app. Writes each step, timed, to `file`;
    /// ends with 0 only if all of it worked.
    static async Task<int> WriteTitle(string file)
    {
        void Log(string line) => File.AppendAllText(file, line + "\n");
        const string Note = "Saturday: milk, eggs, sourdough bread, apples and coffee beans. Pick up the dry cleaning on the way back.";
        async Task Search(string when)
        {
            using var search = new Embedder();  // its own session each time, so the second starts after the writing model's
            var vector = await search.EmbedAsync(Note) ?? throw new InvalidOperationException($"search's model failed {when}");
            Log($"search, {when}: {vector.Length} numbers");
        }
        try
        {
            var model = WritingModel.Shared;
            var clock = Stopwatch.StartNew();
            if (!model.Installed)
            {
                await model.DownloadAsync(null, CancellationToken.None);
                Log($"downloaded {model.SizeText} in {clock.Elapsed.TotalSeconds:0} s");
            }
            await Search("before");
            foreach (var state in new[] { "loading the model", "loaded" })
            {
                clock.Restart();
                var title = await Assistant.Run(model, "title", Note);
                Log($"title, {state}: {clock.Elapsed.TotalSeconds:0.0} s: {title}");
                if (title.Length == 0 || title.Contains('\n')) throw new InvalidOperationException("that isn't a title");
            }
            await Search("after");
            Log($"peak memory: {Process.GetCurrentProcess().PeakWorkingSet64 / 1e9:0.0} GB");
            return 0;  // the writing model stays loaded, as when the app quits soon after a ✨
        }
        catch (Exception e)
        {
            Log(e.ToString());
            return 1;
        }
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
