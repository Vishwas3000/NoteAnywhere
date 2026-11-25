using System.Security.Cryptography;
using System.Text;
using NoteAnywhere.Core.Crypto;

namespace NoteAnywhere.Core.Tests.Crypto;

/// The vectors are Android's (android/app/src/test/java/com/memorynotes/android/VaultTest.kt), made on a Mac by
/// CryptoKit and CommonCrypto exactly as NoteLock.key, CloudSync.createVault and SyncVault do it (demo text only).
/// The Android* ones are Vault.kt's own sealing of the same inputs, as VaultTest.writesVectorsForSwift wrote it.
public class SyncVaultTests
{
    const string Passphrase = "demo passphrase ünïcødé 🔑";
    const string Salt = "AwoRGB8mLTQ7QklQV15lbA==";
    const string DerivedHex = "0ed1442570f9b52350dc01b182d99f67e45720a7114a82f227b3ea41b575bff1";
    const string Wrapped = "hKp2sCFdZfqcawNkXdShq2txkQUDg8sZbeXDLxUWGUefDtnrsUp5FPVWcgYenE6Wh5DiAsrzkPYPzkNT";
    const string VaultKeyHex = "fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0efeeedecebeae9e8e7e6e5e4e3e2e1e0";
    const string Text = "# Demo note\nLine two with émoji 🎉 and **bold**\n\n- [ ] a task @2026-11-03";
    const string SealedText = "mne2e:v1:j01xpPcRwHLfav25B8c33J1a/s391tN+Z1tcB8L+vxuBCZecGv32gbibLYhhLX1YklEzaFZv/hTu55I9Mx8XI8dj6bJ2OZoHeHmqSJZ8XnN/pznTzZdRXBW9sBr3u9jXWE+5+zmwN6Q=";
    const string SealedEmpty = "mne2e:v1:7g70P4QPKY6BAff5x/yUkwhTmtNgLzO2NLJ43g==";
    const string SealedImage = "IyRUB5NGUlYVP3BFrikT+h9KaRsSdDAMVtW966zotXfXOiIKwmOcOhLW3aFKLrPfine/ovZ/RZ8mg8xT3iVlf/uRJuuUu9s39EIMSRDnC0FieQgjJYJLVlpn7G0aQRYfR4K0VO6npd+eDgvqqC3OqnVshl9zQHOzQ4t36zfrR/mfkYMzkJimiVf3Mxqinz6dADup7SlCwwUs7iT9cv41HEr2y8P7QvskImCJ7wl39mb1sWgh47XczCINKXR9Yb5rZT3DcKtJn6Qv87b0buv40PnYKlXNeDiw2af8YpWWBvQfI8i2abJL3GeG1o317LxjbRVNOhZHQHLQQf3jUbf84qtruCTGUwTUCS8w9AI5G8+HKsqFdsNKor9oReb6uf9Vp73YQ1vVMx8ec1L3Q/WeGuczP980/TfELpsVnlqoWpeRdnVtAti1DA==";
    const string AndroidSalt = "TOnX2FjD5KX0a3YF3heY8g==";
    const string AndroidDerivedHex = "2159bd22066f5e0e9f47d39458643434d0ab47abed5a0760765de7ff476ede07";
    const string AndroidWrapped = "pgGqzTsRLPhPzGOKx4vmYqAUTON0Y6AWdO2M98a/XdtX3jWvJb0Lk8fTOXjW+i/uW854Ip648mXe7Xe1";
    const string AndroidVaultKeyHex = "5174298e3390518e1545c70d8f83593854e82f5f5a267166afaa3fdbed71d51c";
    const string AndroidSealedText = "mne2e:v1:ceOIyoX0frZuHZKvZKSm80gJVVMGxH7Y4p+izWNBaUjwZbuDNpFtV1koqnj/39l0GK4roGLz3LBFyrr/crcTa5TtRT0nZP/mJT6pYrVHfzmH1ix0YGScOjMY4qBuDnfC2l9RskECZlE=";
    const string AndroidSealedEmpty = "mne2e:v1:31Q/VU2mo4isYKr15eD+0/HHbSZWEVRh0wU4zQ==";
    const string AndroidSealedImage = "2nIaLQWDiVJ12IQbmWdnxoPMUmgrW3moHQvJ38u0GdOCiXXpW9PDEEkxZpg8kqdRIWFTLRcOJPr3WyO89HDf5rXjDqtn1U6T4aelUW5tBjHV98d5gMfs6LB0Nzw3z7uSz4OTyRVxnJxgoq6d/7ecP7gyNCpbrYa0Kd6raNES4Mg7Tv6hRSXlDJW4stRYtJMNbzUKErjda4z/jFZtC4h8p3cceVpzHqQWn9TArA54xpl89+AKJeJ2gBTDJiaHGsYdVVUKczUVAI3nDWWMgvpBff2MEy55l+cTTnvCo8hdsb+Knhu9SxYZKcQhbVW8JIyVcD4xryYgGm5HLjBrezyHYxSL+tjAYLlg7Lj4aHgFXotmw/Cci5ZNZy8I8a7ZU0H+UYr4W87ouNjFfDlXron9wbbm8vjhAnT4l4Iwtgpq+wgEd0S2dU9NWQ==";
    static readonly byte[] Image = [.. Enumerable.Range(0, 300).Select(i => (byte)(i % 251))];
    static readonly byte[] VaultKey = Convert.FromHexString(VaultKeyHex);

    [Fact]
    public void Pbkdf2MatchesCommonCrypto() =>
        Assert.Equal(DerivedHex, Convert.ToHexStringLower(NoteLock.Key(Passphrase, Convert.FromBase64String(Salt))));

    [Fact]
    public void UnwrapsTheMacsVaultKey() =>
        Assert.Equal(VaultKeyHex, Convert.ToHexStringLower(SyncVault.UnwrapKey(Passphrase, Salt, Wrapped)));

    [Fact]
    public void AWrongPassphraseFailsCleanly()
    {
        var error = Assert.Throws<CryptographicException>(() => SyncVault.UnwrapKey("wrong passphrase", Salt, Wrapped));
        Assert.Equal("That passphrase doesn't open your synced notes.", error.Message);
    }

    [Fact]
    public void OpensMacFields()
    {
        Assert.Equal(Text, SyncVault.Open(SealedText, VaultKey));
        Assert.Equal("", SyncVault.Open(SealedEmpty, VaultKey));
    }

    [Fact]
    public void OpensMacImages() => Assert.Equal(Image, SyncVault.Open(Convert.FromBase64String(SealedImage), VaultKey));

    [Fact]
    public void OpensAndroidsOwnSealing()
    {
        Assert.Equal(AndroidDerivedHex, Convert.ToHexStringLower(NoteLock.Key(Passphrase, Convert.FromBase64String(AndroidSalt))));
        var key = SyncVault.UnwrapKey(Passphrase, AndroidSalt, AndroidWrapped);
        Assert.Equal(AndroidVaultKeyHex, Convert.ToHexStringLower(key));
        Assert.Equal(Text, SyncVault.Open(AndroidSealedText, key));
        Assert.Equal("", SyncVault.Open(AndroidSealedEmpty, key));
        Assert.Equal(Image, SyncVault.Open(Convert.FromBase64String(AndroidSealedImage), key));
    }

    [Fact]
    public void RefusesUnsealedText()
    {
        var error = Assert.Throws<CryptographicException>(() => SyncVault.Open("plain text", VaultKey));
        Assert.Equal("A synced note can't be read with this passphrase.", error.Message);
    }

    [Fact]
    public void AnotherVaultKeyOpensNothing()
    {
        var other = RandomNumberGenerator.GetBytes(32);
        Assert.Throws<CryptographicException>(() => SyncVault.Open(SealedText, other));
        var error = Assert.Throws<CryptographicException>(() => SyncVault.Open(Convert.FromBase64String(SealedImage), other));
        Assert.Equal("A synced image can't be read with this passphrase.", error.Message);
    }

    [Theory]
    [InlineData(0)]  // nonce
    [InlineData(12)]  // ciphertext
    [InlineData(-1)]  // tag
    public void TamperingIsRefused(int index)
    {
        var text = SyncVault.Prefix + Convert.ToBase64String(Flip(SealedText[SyncVault.Prefix.Length..], index));
        Assert.Throws<CryptographicException>(() => SyncVault.Open(text, VaultKey));
        Assert.Throws<CryptographicException>(() => SyncVault.Open(Flip(SealedImage, index), VaultKey));
        Assert.Throws<CryptographicException>(() => SyncVault.UnwrapKey(Passphrase, Salt, Convert.ToBase64String(Flip(Wrapped, index))));
    }

    [Fact]
    public void SealRoundTrips()
    {
        var sealedText = SyncVault.Seal(Text, VaultKey);
        Assert.StartsWith("mne2e:v1:", sealedText);
        Assert.Equal(12 + Encoding.UTF8.GetByteCount(Text) + 16, Convert.FromBase64String(sealedText[SyncVault.Prefix.Length..]).Length);
        Assert.Equal(Text, SyncVault.Open(sealedText, VaultKey));
        Assert.Equal("", SyncVault.Open(SyncVault.Seal("", VaultKey), VaultKey));
        Assert.Equal(Image, SyncVault.Open(SyncVault.Seal(Image, VaultKey), VaultKey));
    }

    [Fact]
    public void ANewVaultKeyUnwrapsOnlyWithItsPassphrase()
    {
        var (key, salt, wrapped) = SyncVault.CreateKey(Passphrase);
        Assert.Equal(32, key.Length);
        Assert.Equal(key, SyncVault.UnwrapKey(Passphrase, salt, wrapped));
        Assert.Throws<CryptographicException>(() => SyncVault.UnwrapKey("wrong passphrase", salt, wrapped));
    }

    [Fact]
    public void TheVaultKeyIsKeptPerAccount()
    {
        var secrets = new MemorySecretStore();
        SyncVault.SaveKey(secrets, "user-a", VaultKey);
        Assert.Equal(VaultKey, SyncVault.SavedKey(secrets, "user-a"));
        Assert.Null(SyncVault.SavedKey(secrets, "user-b"));
        SyncVault.DeleteKey(secrets, "user-a");
        Assert.Null(SyncVault.SavedKey(secrets, "user-a"));
        secrets.Set("vault-user-c", new byte[16]);
        Assert.Null(SyncVault.SavedKey(secrets, "user-c"));
    }

    static byte[] Flip(string base64, int index)
    {
        var data = Convert.FromBase64String(base64);
        data[index < 0 ? data.Length + index : index] ^= 1;
        return data;
    }
}
