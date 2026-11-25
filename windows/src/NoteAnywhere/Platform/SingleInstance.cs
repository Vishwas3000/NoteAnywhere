using System.Threading;

namespace NoteAnywhere.Platform;

/// One app per Windows session: starting it again shows the running one's window and quits. The browser host and the
/// MCP server are other roles of the same program and run alongside, so they never come through here.
sealed class SingleInstance : IDisposable
{
    readonly Mutex mutex;
    readonly EventWaitHandle show = new(false, EventResetMode.AutoReset, @"Local\NoteAnywhere.Show");

    public bool IsFirst { get; }

    public SingleInstance()
    {
        mutex = new Mutex(true, @"Local\NoteAnywhere.App", out var created);
        IsFirst = created;
    }

    public void ShowTheFirst() => show.Set();

    /// Runs `onShow` (on a background thread) each time another start asks.
    public void ListenForShow(Action onShow) =>
        new Thread(() => { while (show.WaitOne()) onShow(); }) { IsBackground = true, Name = "NoteAnywhere.Show" }.Start();

    public void Dispose()
    {
        if (IsFirst) mutex.ReleaseMutex();
        mutex.Dispose();
    }
}
