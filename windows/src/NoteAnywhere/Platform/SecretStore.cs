using System.IO;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using NoteAnywhere.Core;
using NoteAnywhere.Core.Crypto;

namespace NoteAnywhere.Platform;

/// The Mac's Keychain on Windows: the sync session, each account's vault key and the notes password, a file each in
/// secrets\ beside the notes, sealed by DPAPI so that only this Windows user can open them.
[SupportedOSPlatform("windows")]
sealed class SecretStore : ISecretStore
{
    static readonly byte[] Entropy = "NoteAnywhere secrets"u8.ToArray();
    static string Dir => Path.Combine(AppPaths.Data, "secrets");

    public byte[]? Get(string name)
    {
        try
        {
            return ProtectedData.Unprotect(File.ReadAllBytes(PathOf(name)), Entropy, DataProtectionScope.CurrentUser);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or CryptographicException)
        {
            return null;  // none, or one this user can't open (damaged, another PC's): as the Mac's Keychain, signed out
        }
    }

    public void Set(string name, byte[] value)
    {
        var path = PathOf(name);
        Directory.CreateDirectory(Dir);
        var temporary = path + ".tmp";  // then replaced: a crash never leaves half a secret
        File.WriteAllBytes(temporary, ProtectedData.Protect(value, Entropy, DataProtectionScope.CurrentUser));
        File.Move(temporary, path, overwrite: true);
    }

    public void Delete(string name)
    {
        var path = PathOf(name);
        if (File.Exists(path)) File.Delete(path);
    }

    // Names are this app's own words and account ids from the server: nothing that could reach outside the folder.
    static string PathOf(string name) => name.Length > 0 && name.All(c => char.IsAsciiLetterOrDigit(c) || c == '-')
        ? Path.Combine(Dir, name)
        : throw new ArgumentException($"Not a secret's name: {name}", nameof(name));
}
