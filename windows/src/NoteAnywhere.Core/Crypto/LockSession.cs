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

    /// A notes password exists once a note was locked anywhere: its check value here, or a locked note synced from another
    /// device, whose password unlocking proves (a new one would split the notes between two passwords).
    public static bool HasPassword(IEnumerable<Note> notes) =>
        NoteStore.SyncValue("lock.check") != null || notes.Any(n => n.Locked && NoteLock.IsEnvelope(n.Text));

    /// The first lock's password and hint, by the rules of the Mac's NotesPasswordSheet; throws ArgumentException with a
    /// message to show.
    public void SetPassword(string password, string hint)
    {
        if (password.Length < 4) throw new ArgumentException("Use at least 4 characters.");
        if (password == hint) throw new ArgumentException("The hint can't be the password.");
        NoteStore.SetSyncValue("lock.check", NoteLock.MakeCheck(password));
        NoteStore.SetSyncValue("lock.hint", hint.Length == 0 ? null : hint);
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
