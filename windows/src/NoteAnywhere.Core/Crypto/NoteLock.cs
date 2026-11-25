using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;

namespace NoteAnywhere.Core.Crypto;

/// Locked notes, as on the Mac (NoteLock.swift): one notes password; a locked note's text is the envelope
/// "mnlock:v1:" + base64(salt | nonce | ciphertext | tag), AES-256-GCM keyed by PBKDF2-SHA256(password, salt).
/// A forgotten password can't be recovered.
public static class NoteLock
{
    public const string Prefix = "mnlock:v1:";
    const int Iterations = 310_000;
    const int SaltSize = 16;
    const string CheckText = "noteanywhere-lock-check";
    const string PasswordName = "notes-password";

    // Keyed by a hash of the password, as the Mac keeps it: no typed password stays in memory for the app's lifetime.
    static readonly ConcurrentDictionary<(string PasswordHash, string Salt), byte[]> keys = new();

    public static bool IsEnvelope(string text) => text.StartsWith(Prefix, StringComparison.Ordinal);

    /// Encrypts with a fresh salt, or `reusing` an existing envelope's salt so re-saving while typing stays fast.
    public static string Seal(string plaintext, string password, string? reusing = null)
    {
        var salt = (reusing is null ? null : Parts(reusing)?.Salt) ?? RandomNumberGenerator.GetBytes(SaltSize);
        return Prefix + Convert.ToBase64String([.. salt, .. SealedBox.Seal(Encoding.UTF8.GetBytes(plaintext), Key(password, salt))]);
    }

    /// Throws CryptographicException, with a message to show, when the envelope is damaged or the password is wrong.
    public static string Open(string envelope, string password)
    {
        var (salt, box) = Parts(envelope) ?? throw new CryptographicException("This locked note is damaged.");
        var plain = SealedBox.Open(box, Key(password, salt)) ?? throw new CryptographicException("That password doesn't open this note.");
        return Encoding.UTF8.GetString(plain);
    }

    // The Mac's parts() also refuses an envelope of exactly salt + nonce + tag, which is what its own seal("") writes;
    // here that opens as the empty note it is.
    static (byte[] Salt, byte[] Box)? Parts(string envelope) =>
        IsEnvelope(envelope) && SealedBox.FromBase64(envelope[Prefix.Length..]) is { Length: >= SaltSize + SealedBox.Overhead } data
            ? (data[..SaltSize], data[SaltSize..])
            : null;

    /// PBKDF2-SHA256 → 256-bit key; also the sync passphrase's key (see SyncVault). Each password and salt is derived
    /// once per run: a derivation takes a noticeable fraction of a second.
    public static byte[] Key(string password, byte[] salt) =>
        keys.GetOrAdd((Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(password))), Convert.ToBase64String(salt)),
                      _ => Rfc2898DeriveBytes.Pbkdf2(password, salt, Iterations, HashAlgorithmName.SHA256, 32))
            .ToArray();  // a copy, so a caller wiping its key can't wipe the cache

    /// The notes password's check value, which the notes database keeps as "lock.check": it tells a right password
    /// from a wrong one before any note is locked on this device.
    public static string MakeCheck(string password) => Seal(CheckText, password);

    public static bool IsPassword(string password, string check)
    {
        try
        {
            return Open(check, password) == CheckText;
        }
        catch (CryptographicException)
        {
            return false;
        }
    }

    /// The notes password, kept on this device so locked notes can open without typing it (Touch ID on the Mac).
    public static void SavePassword(ISecretStore secrets, string password) =>
        secrets.Set(PasswordName, Encoding.UTF8.GetBytes(password));

    public static string? SavedPassword(ISecretStore secrets) =>
        secrets.Get(PasswordName) is { } bytes ? Encoding.UTF8.GetString(bytes) : null;
}
