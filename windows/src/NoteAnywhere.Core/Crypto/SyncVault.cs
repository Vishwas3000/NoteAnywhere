using System.Security.Cryptography;
using System.Text;

namespace NoteAnywhere.Core.Crypto;

/// Sync's end-to-end encryption, as on the Mac (SyncCloud.swift) and Android (Vault.kt). Each note's text, place and
/// title, each snapshot's text and each folder's name go up as "mne2e:v1:" + base64(nonce | ciphertext | tag),
/// AES-256-GCM with the account's vault key; image bytes as the bare nonce | ciphertext | tag. The server keeps the
/// vault key only wrapped by the sync passphrase.
public static class SyncVault
{
    public const string Prefix = "mne2e:v1:";

    public static string Seal(string text, byte[] key) =>
        Prefix + Convert.ToBase64String(SealedBox.Seal(Encoding.UTF8.GetBytes(text), key));

    /// Throws CryptographicException, with a message to show, when the text isn't sealed or the key is wrong.
    public static string Open(string text, byte[] key)
    {
        var data = text.StartsWith(Prefix, StringComparison.Ordinal) ? SealedBox.FromBase64(text[Prefix.Length..]) : null;
        var plain = (data is null ? null : SealedBox.Open(data, key))
            ?? throw new CryptographicException("A synced note can't be read with this passphrase.");
        return Encoding.UTF8.GetString(plain);
    }

    public static byte[] Seal(byte[] image, byte[] key) => SealedBox.Seal(image, key);

    public static byte[] Open(byte[] image, byte[] key) =>
        SealedBox.Open(image, key) ?? throw new CryptographicException("A synced image can't be read with this passphrase.");

    /// First device: a new random vault key, and the salt and wrapped key (base64) for the server's `vaults` row.
    public static (byte[] Key, string Salt, string Wrapped) CreateKey(string passphrase)
    {
        var key = RandomNumberGenerator.GetBytes(32);
        var salt = RandomNumberGenerator.GetBytes(16);
        return (key, Convert.ToBase64String(salt), Convert.ToBase64String(SealedBox.Seal(key, NoteLock.Key(passphrase, salt))));
    }

    /// Any other device: the vault key, from the `vaults` row's salt and wrapped key.
    public static byte[] UnwrapKey(string passphrase, string salt, string wrapped)
    {
        var s = SealedBox.FromBase64(salt);
        var w = SealedBox.FromBase64(wrapped);
        var key = s is null || w is null ? null : SealedBox.Open(w, NoteLock.Key(passphrase, s));
        return key is { Length: 32 } ? key : throw new CryptographicException("That passphrase doesn't open your synced notes.");
    }

    /// The vault key, kept per account on this device only.
    public static byte[]? SavedKey(ISecretStore secrets, string userId) =>
        secrets.Get(KeyName(userId)) is { Length: 32 } key ? key : null;

    public static void SaveKey(ISecretStore secrets, string userId, byte[] key) => secrets.Set(KeyName(userId), key);

    public static void DeleteKey(ISecretStore secrets, string userId) => secrets.Delete(KeyName(userId));

    static string KeyName(string userId) => "vault-" + userId;
}
