using System.Text;
using NoteAnywhere.Core;

namespace NoteAnywhere.Core.Tests;

public class NativeMessagingTests
{
    [Fact]
    public void FramesRoundTripAndAClosedPipeEndsTheLoop()
    {
        var pipe = new MemoryStream();
        NativeMessaging.Write(pipe, Encoding.UTF8.GetBytes("""{"op":"list","url":"github.com"}"""));
        NativeMessaging.Write(pipe, Encoding.UTF8.GetBytes("""{"op":"watch"}"""));
        Assert.Equal([32, 0, 0, 0], pipe.ToArray()[..4]);  // little-endian length, as Chrome writes it
        pipe.Position = 0;
        Assert.Equal("""{"op":"list","url":"github.com"}""", Encoding.UTF8.GetString(NativeMessaging.Read(pipe)!));
        Assert.Equal("""{"op":"watch"}""", Encoding.UTF8.GetString(NativeMessaging.Read(pipe)!));
        Assert.Null(NativeMessaging.Read(pipe));
    }

    [Fact]
    public void AHalfWrittenMessageCountsAsClosed()
    {
        var pipe = new MemoryStream([10, 0, 0, 0, (byte)'{']);
        Assert.Null(NativeMessaging.Read(pipe));
    }
}
