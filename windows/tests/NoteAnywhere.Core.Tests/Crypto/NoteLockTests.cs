using System.Security.Cryptography;
using System.Text;
using NoteAnywhere.Core.Crypto;

namespace NoteAnywhere.Core.Tests.Crypto;

/// The Mac* envelopes were sealed on a Mac by NoteLock.swift's own NoteLock enum, compiled as is (demo text only).
/// MacCheck is the "lock.check" value LockSession.setPassword stores for that password.
public class NoteLockTests
{
    const string Password = "demo password ünïcødé 🔒";
    const string Text = "# Demo note\nLine two with émoji 🎉 and **bold**\n\n- [ ] a task @2026-11-03";
    const string MacEnvelope = "mnlock:v1:4NQnxjSCb61CRIVd8+67sEXv91d6PvlJuaDBCcuO9WUT5zxWi9OTZ1iQgZSmDYsH6xB+GgxefivrAKavulQWdgf8riVmQgf4AZLjFmf5MamtFfqZalSjN+ckp9kYvVKvR2fRQ95aE/w24M0ggbZ7KE/ukknxgOC5";
    const string MacCheck = "mnlock:v1:OsFtmNE5wMjAvqKkoy2FikBHNvGbzRlmk9n1VRS8Jxh864se4nhYkOKUCIhsCGMiaCw2/3KtkuuCWPgmgsvbUeJLRg==";
    const string MacEmpty = "mnlock:v1:wMBui7rP1HJ7cTd0mDwyigXY1XaEqJJlg6ib9xHaCF98SzDKDFRUHYozYT4=";

    [Fact]
    public void OpensTheMacsLockedNote() => Assert.Equal(Text, NoteLock.Open(MacEnvelope, Password));

    // The Mac's own open() refuses this one as damaged (see NoteLock.Parts).
    [Fact]
    public void OpensTheMacsEmptyLockedNote() => Assert.Equal("", NoteLock.Open(MacEmpty, Password));

    [Fact]
    public void TheMacsCheckValueTellsTheRightPassword()
    {
        Assert.True(NoteLock.IsPassword(Password, MacCheck));
        Assert.False(NoteLock.IsPassword("wrong", MacCheck));
        Assert.False(NoteLock.IsPassword(Password, MacEnvelope));
    }

    [Fact]
    public void AWrongPasswordFailsCleanly()
    {
        var error = Assert.Throws<CryptographicException>(() => NoteLock.Open(MacEnvelope, "wrong"));
        Assert.Equal("That password doesn't open this note.", error.Message);
    }

    [Theory]
    [InlineData(0)]  // salt
    [InlineData(16)]  // nonce
    [InlineData(28)]  // ciphertext
    [InlineData(-1)]  // tag
    public void ATamperedEnvelopeIsRefused(int index) =>
        Assert.Throws<CryptographicException>(() => NoteLock.Open(Flip(MacEnvelope, index), Password));

    [Theory]
    [InlineData("mnlock:v1:garbage")]
    [InlineData("mnlock:v1:AAAA")]
    [InlineData("plain text")]
    public void ADamagedEnvelopeSaysSo(string envelope)
    {
        var error = Assert.Throws<CryptographicException>(() => NoteLock.Open(envelope, Password));
        Assert.Equal("This locked note is damaged.", error.Message);
    }

    [Fact]
    public void SealRoundTrips()
    {
        var envelope = NoteLock.Seal(Text, Password);
        Assert.True(NoteLock.IsEnvelope(envelope));
        Assert.Equal(16 + 12 + Encoding.UTF8.GetByteCount(Text) + 16, Convert.FromBase64String(envelope[NoteLock.Prefix.Length..]).Length);
        Assert.Equal(Text, NoteLock.Open(envelope, Password));
        Assert.Equal("", NoteLock.Open(NoteLock.Seal("", Password), Password));
    }

    [Fact]
    public void ResealingKeepsTheSaltWithAFreshNonce()
    {
        var again = NoteLock.Seal(Text + " more", Password, reusing: MacEnvelope);
        var before = Convert.FromBase64String(MacEnvelope[NoteLock.Prefix.Length..]);
        var after = Convert.FromBase64String(again[NoteLock.Prefix.Length..]);
        Assert.Equal(before[..16], after[..16]);
        Assert.NotEqual(before[16..28], after[16..28]);
        Assert.Equal(Text + " more", NoteLock.Open(again, Password));
    }

    [Fact]
    public void ANewCheckValueTellsTheRightPassword()
    {
        var check = NoteLock.MakeCheck(Password);
        Assert.True(NoteLock.IsPassword(Password, check));
        Assert.False(NoteLock.IsPassword("wrong", check));
    }

    [Fact]
    public void ThePasswordIsKeptInTheSecretStore()
    {
        var secrets = new MemorySecretStore();
        Assert.Null(NoteLock.SavedPassword(secrets));
        NoteLock.SavePassword(secrets, Password);
        Assert.Equal(Password, NoteLock.SavedPassword(secrets));
    }

    static string Flip(string envelope, int index)
    {
        var data = Convert.FromBase64String(envelope[NoteLock.Prefix.Length..]);
        data[index < 0 ? data.Length + index : index] ^= 1;
        return NoteLock.Prefix + Convert.ToBase64String(data);
    }
}
