using System.Buffers.Binary;

namespace NoteAnywhere.Core;

/// Browser native messaging's framing, the same on every system: a 4-byte little-endian length, then UTF-8 JSON.
public static class NativeMessaging
{
    /// Null when the browser closed the pipe.
    public static byte[]? Read(Stream input)
    {
        var header = new byte[4];
        if (!ReadExactly(input, header)) return null;
        var body = new byte[BinaryPrimitives.ReadUInt32LittleEndian(header)];
        return ReadExactly(input, body) ? body : null;
    }

    public static void Write(Stream output, ReadOnlySpan<byte> json)
    {
        Span<byte> header = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(header, (uint)json.Length);
        output.Write(header);
        output.Write(json);
        output.Flush();
    }

    static bool ReadExactly(Stream input, byte[] buffer)
    {
        try { input.ReadExactly(buffer); return true; }
        catch (EndOfStreamException) { return false; }
    }
}
