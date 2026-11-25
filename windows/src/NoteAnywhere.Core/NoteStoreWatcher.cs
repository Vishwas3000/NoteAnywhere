using Microsoft.Data.Sqlite;

namespace NoteAnywhere.Core;

/// Raises Changed (on a thread-pool thread) after any other connection commits a write: the Mac's Darwin notification, for caches and sync bookkeeping too.
// Polling, because Windows has nothing like Darwin notify that every writer posts and every process hears, and data_version moves on any other connection's commit for the cost of a memory read.
public sealed class NoteStoreWatcher : IDisposable
{
    readonly Lock gate = new();
    readonly SqliteConnection db = NoteStore.Open(NoteStore.DatabasePath);
    readonly Timer timer;
    long version;
    bool disposed;

    public event Action? Changed;

    /// Polls every `interval`, half a second unless given; with Timeout.InfiniteTimeSpan only Poll() does.
    public NoteStoreWatcher(TimeSpan? interval = null)
    {
        version = DataVersion();
        var every = interval ?? TimeSpan.FromMilliseconds(500);
        timer = new Timer(_ =>
        {
            try { Poll(); }
            catch (SqliteException) { }  // a busy or failing read is tried again next tick; Poll() itself throws
        }, null, every, every);
    }

    /// True, after raising Changed, when another connection has committed since the last poll.
    public bool Poll()
    {
        lock (gate)
        {
            if (disposed) return false;
            var now = DataVersion();
            if (now == version) return false;
            version = now;
        }
        Changed?.Invoke();
        return true;
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            timer.Dispose();
            db.Dispose();
        }
    }

    long DataVersion()
    {
        using var command = db.CreateCommand();
        command.CommandText = "PRAGMA data_version";
        return (long)command.ExecuteScalar()!;
    }
}
