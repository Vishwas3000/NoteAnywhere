using System.Security.Cryptography;

namespace NoteAnywhere.Core.Crypto;

/// Whether locked notes are open right now, as the Mac's LockSession: the notes password, checked against the check
/// value the notes database keeps ("lock.check"), stays in memory until Lock Notes, Windows locks or the app quits.
/// Nothing on this PC keeps it, so nothing opens a locked note without it being typed.
public sealed class LockSession
{
    public static LockSession Shared { get; } = new();

    /// Raised on the thread that unlocked or locked.
    public event Action? Changed;

    public string? Password { get; private set; }
    public bool IsUnlocked => Password != null;
    public static string? Hint => NoteStore.SyncValue("lock.hint");

    /// Throws CryptographicException with a message to show. `notes`: the notes as the app has them; on a PC that never
    /// checked the password, the first locked one that opens proves it, and its check value is kept from then on.
    public void Unlock(string password, IEnumerable<Note> notes)
    {
        var wrong = new CryptographicException("Wrong password.");
        if (NoteStore.SyncValue("lock.check") is { } check)
        {
            if (!NoteLock.IsPassword(password, check)) throw wrong;
        }
        else if (notes.FirstOrDefault(n => n.Locked && NoteLock.IsEnvelope(n.Text)) is { } note)
        {
            try { NoteLock.Open(note.Text, password); }
            catch (CryptographicException) { throw wrong; }
            NoteStore.SetSyncValue("lock.check", NoteLock.MakeCheck(password));
        }
        else throw new CryptographicException("No note is locked yet.");
        Password = password;
        Changed?.Invoke();
    }

    public void LockNow()
    {
        if (Password is null) return;
        Password = null;
        Changed?.Invoke();
    }
}
