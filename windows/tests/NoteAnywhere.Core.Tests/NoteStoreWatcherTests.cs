namespace NoteAnywhere.Core.Tests;

/// The Mac posts a Darwin notification after every commit; here other processes poll PRAGMA data_version.
[Collection("NoteStore")]
public class NoteStoreWatcherTests
{
    public NoteStoreWatcherTests() => Assert.True(AppPaths.Data == Scratch.Dir, "would touch the real notes database");

    [Fact]
    public void SeesWhatOtherConnectionsCommit()
    {
        using var watcher = new NoteStoreWatcher(Timeout.InfiniteTimeSpan);
        var raised = 0;
        watcher.Changed += () => raised++;
        Assert.False(watcher.Poll());

        NoteStore.Save(new Note { Kind = NoteKind.Url, Target = "", Label = "", Text = "watched" });  // NoteStore's own connection
        Assert.True(watcher.Poll());
        Assert.Equal(1, raised);
        Assert.False(watcher.Poll());  // once per commit

        NoteStore.Delete("0000");  // a commit that writes nothing
        Assert.False(watcher.Poll());

        using (var other = NoteStore.Open(NoteStore.DatabasePath))  // as another process would
        using (var command = other.CreateCommand())
        {
            command.CommandText = "INSERT OR REPLACE INTO sync_state (key, value) VALUES ('watched', '1')";
            command.ExecuteNonQuery();
        }
        Assert.True(watcher.Poll());
        Assert.Equal(2, raised);

        watcher.Dispose();
        Assert.False(watcher.Poll());
    }

    [Fact]
    public async Task RaisesChangedOnItsOwn()
    {
        using var watcher = new NoteStoreWatcher(TimeSpan.FromMilliseconds(20));
        var changed = new TaskCompletionSource();
        watcher.Changed += () => changed.TrySetResult();
        NoteStore.Save(new Note { Kind = NoteKind.Url, Target = "", Label = "", Text = "polled" });
        Assert.Same(changed.Task, await Task.WhenAny(changed.Task, Task.Delay(TimeSpan.FromSeconds(10))));
    }
}
