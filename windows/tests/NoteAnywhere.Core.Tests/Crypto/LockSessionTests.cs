using System.Security.Cryptography;
using NoteAnywhere.Core.Crypto;

namespace NoteAnywhere.Core.Tests.Crypto;

/// Unlocking with the Mac's own check value and envelope (NoteLockTests). One class, so its tests take turns with the
/// store's single "lock.check".
public class LockSessionTests
{
    static Note Locked(string envelope) => new() { Kind = NoteKind.App, Target = "win.notepad/x.txt", Label = "Notepad", Text = envelope, Locked = true };

    [Fact]
    public void TheMacsCheckValueTellsTheRightPasswordFromAWrongOne()
    {
        NoteStore.SetSyncValue("lock.check", NoteLockTests.MacCheck);
        var session = new LockSession();
        var changes = 0;
        session.Changed += () => changes++;
        Assert.Equal("Wrong password.", Assert.Throws<CryptographicException>(() => session.Unlock("nope", [])).Message);
        Assert.False(session.IsUnlocked);
        session.Unlock(NoteLockTests.Password, []);
        Assert.Equal(NoteLockTests.Password, session.Password);
        session.LockNow();
        session.LockNow();  // already locked: nothing changes
        Assert.Null(session.Password);
        Assert.Equal(2, changes);
    }

    [Fact]
    public void OnAPcThatNeverCheckedItANoteLockedOnTheMacProvesThePasswordAndItsCheckIsKept()
    {
        NoteStore.SetSyncValue("lock.check", null);
        var notes = new[] { new Note { Kind = NoteKind.Url, Target = "example.com", Label = "Example" }, Locked(NoteLockTests.MacEnvelope) };
        var session = new LockSession();
        Assert.Equal("Wrong password.", Assert.Throws<CryptographicException>(() => session.Unlock("nope", notes)).Message);
        Assert.Null(NoteStore.SyncValue("lock.check"));
        session.Unlock(NoteLockTests.Password, notes);
        Assert.True(session.IsUnlocked);
        Assert.True(NoteLock.IsPassword(NoteLockTests.Password, NoteStore.SyncValue("lock.check")!));
    }

    [Fact]
    public void WithNothingLockedThereIsNoPasswordToCheck()
    {
        NoteStore.SetSyncValue("lock.check", null);
        var error = Assert.Throws<CryptographicException>(() => new LockSession().Unlock("anything", [new Note { Kind = NoteKind.Url, Target = "a.com", Label = "A" }]));
        Assert.Equal("No note is locked yet.", error.Message);
    }
}
