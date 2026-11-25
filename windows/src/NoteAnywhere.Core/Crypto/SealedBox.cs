using System.Security.Cryptography;

namespace NoteAnywhere.Core.Crypto;

/// AES-GCM in CryptoKit's "combined" layout, the one every NoteAnywhere format is built on:
/// 12-byte nonce | ciphertext | 16-byte tag.
static class SealedBox
{
    const int NonceSize = 12, TagSize = 16;
    public const int Overhead = NonceSize + TagSize;

    public static byte[] Seal(ReadOnlySpan<byte> plain, ReadOnlySpan<byte> key)
    {
        var box = new byte[NonceSize + plain.Length + TagSize];
        RandomNumberGenerator.Fill(box.AsSpan(0, NonceSize));
        using var aes = new AesGcm(key, TagSize);
        aes.Encrypt(box.AsSpan(0, NonceSize), plain, box.AsSpan(NonceSize, plain.Length), box.AsSpan(NonceSize + plain.Length));
        return box;
    }

    /// Null when the key is wrong or the box is damaged.
    public static byte[]? Open(ReadOnlySpan<byte> box, ReadOnlySpan<byte> key)
    {
        if (box.Length < Overhead) return null;
        var plain = new byte[box.Length - Overhead];
        using var aes = new AesGcm(key, TagSize);
        try
        {
            aes.Decrypt(box[..NonceSize], box[NonceSize..^TagSize], box[^TagSize..], plain);
            return plain;
        }
        catch (CryptographicException)
        {
            return null;
        }
    }

    public static byte[]? FromBase64(string text)
    {
        try
        {
            return Convert.FromBase64String(text);
        }
        catch (FormatException)
        {
            return null;
        }
    }
}
