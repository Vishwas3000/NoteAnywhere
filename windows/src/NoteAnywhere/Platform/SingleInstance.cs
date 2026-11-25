using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Threading;
using System.Windows;

namespace NoteAnywhere.Platform;

/// One app per Windows session: starting it again hands what that start was given (nothing, or a memorynotes:// link
/// from a sign-in email or Google) to the running one over a pipe, and quits. The browser host and the MCP server are
/// other roles of the same program and run alongside, so they never come through here.
sealed class SingleInstance : IDisposable
{
    // Pipe names are machine-wide, unlike the mutex's Local\ one: the session keeps each signed-in user to their own.
    static readonly string Pipe = $"NoteAnywhere.App.{Process.GetCurrentProcess().SessionId}";
    readonly Mutex mutex;

    public bool IsFirst { get; }

    public SingleInstance()
    {
        mutex = new Mutex(true, @"Local\NoteAnywhere.App", out var created);
        IsFirst = created;
    }

    /// From a second start: the running app shows its window, or opens `link`.
    public static void Tell(string? link)
    {
        Win32.AllowSetForegroundWindow(Win32.ASFW_ANY);  // this start came from a click, so the running app may come to the front
        try
        {
            using var pipe = new NamedPipeClientStream(".", Pipe, PipeDirection.Out, PipeOptions.CurrentUserOnly);
            pipe.Connect(10_000);  // it may be starting itself
            using var writer = new StreamWriter(pipe);
            writer.WriteLine(link ?? "");
        }
        catch (Exception e) when (e is TimeoutException or IOException or UnauthorizedAccessException)
        {
            MessageBox.Show($"NoteAnywhere is already running but didn't answer ({e.Message}). Quit it from the notification area and try again.",
                "NoteAnywhere", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    /// Runs `onMessage` (on a background thread) for each later start: null to show the window, else the link it brought.
    public void Listen(Action<string?> onMessage) => new Thread(() =>
    {
        try
        {
            while (true)
            {
                using var pipe = new NamedPipeServerStream(Pipe, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.CurrentUserOnly);
                try
                {
                    pipe.WaitForConnection();
                    using var reader = new StreamReader(pipe);
                    onMessage(reader.ReadLine() is { Length: > 0 } link ? link : null);
                }
                catch (IOException) { }  // a start that gave up halfway
            }
        }
        catch (Exception e)
        {
            CrashLog.Write(e);  // later starts can't reach this one now; crash.log says why
        }
    }) { IsBackground = true, Name = "NoteAnywhere.Show" }.Start();

    public void Dispose()
    {
        if (IsFirst) mutex.ReleaseMutex();
        mutex.Dispose();
    }
}
