using System.Runtime.Versioning;
using NoteAnywhere.Core.Crypto;
using NoteAnywhere.Platform;

namespace NoteAnywhere.Core.Tests;

/// DPAPI is Windows only: skipped elsewhere, run by CI on its Windows machines.
sealed class WindowsFactAttribute : FactAttribute
{
    public WindowsFactAttribute()
    {
        if (!OperatingSystem.IsWindows()) Skip = "DPAPI is Windows only.";
    }
}

/// The app's secret store (src/NoteAnywhere/Platform/SecretStore.cs): where Windows keeps what the Mac keeps in its Keychain.
public class SecretStoreTests
{
    public SecretStoreTests() => Assert.True(AppPaths.Data == Scratch.Dir, "would touch the real secrets");

    [WindowsFact]
    [SupportedOSPlatform("windows")]
    public void KeepsSecretsSealedForThisUser()
    {
        var secrets = new SecretStore();
        var user = Guid.NewGuid().ToString();
        Assert.Null(secrets.Get("session"));
        secrets.Set("session", """{"access_token":"secret-token"}"""u8.ToArray());
        Assert.Equal("""{"access_token":"secret-token"}"""u8.ToArray(), secrets.Get("session"));
        var file = Path.Combine(AppPaths.Data, "secrets", "session");
        Assert.DoesNotContain("secret-token", File.ReadAllText(file));  // sealed on disk
        Assert.Empty(Directory.GetFiles(Path.GetDirectoryName(file)!, "*.tmp"));

        // Replaced, kept per account (as SyncVault names them), and deleted, even twice.
        secrets.Set("session", [1, 2, 3]);
        Assert.Equal([1, 2, 3], secrets.Get("session"));
        var key = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();
        SyncVault.SaveKey(secrets, user, key);
        Assert.Equal(key, SyncVault.SavedKey(secrets, user));
        SyncVault.DeleteKey(secrets, user);
        Assert.Null(SyncVault.SavedKey(secrets, user));
        secrets.Delete("session");
        secrets.Delete("session");
        Assert.Null(secrets.Get("session"));

        // A damaged file reads as none (sign in again), not a crash; and a name can't lead out of the folder.
        File.WriteAllBytes(file, [1, 2, 3]);
        Assert.Null(secrets.Get("session"));
        Assert.Throws<ArgumentException>(() => secrets.Set(@"..\notes", [1]));
        Assert.Throws<ArgumentException>(() => secrets.Get("../notes"));
    }
}
