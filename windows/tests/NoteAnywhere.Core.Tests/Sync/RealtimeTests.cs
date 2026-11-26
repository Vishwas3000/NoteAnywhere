using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using NoteAnywhere.Core.Sync;

namespace NoteAnywhere.Core.Tests.Sync;

/// Realtime against a WebSocket server on this machine, speaking the Phoenix messages the Mac's Realtime sends and reads.
public class RealtimeTests
{
    [Fact]
    public async Task JoinsReportsChangesAndComesBackWhenDropped()
    {
        using var server = new LoopbackSocket();
        var realtime = new Realtime { RetryAfter = TimeSpan.FromMilliseconds(50) };
        var changes = new SemaphoreSlim(0);
        realtime.Changed += () => changes.Release();
        realtime.Connect(server.Url, "token-1");
        var socket = (await server.Accept())!;
        Assert.Equal("GET /realtime/v1/websocket?apikey=test&vsn=1.0.0 HTTP/1.1", server.RequestLine);
        var join = await LoopbackSocket.Receive(socket);
        Assert.Equal("""{"topic":"realtime:memorynotes","event":"phx_join","payload":{"config":{"postgres_changes":[{"event":"*","schema":"public","table":"notes"},{"event":"*","schema":"public","table":"folders"}]},"access_token":"token-1"},"ref":"1"}""",
            join.ToJsonString());

        // Other news isn't a change; a row's is.
        await LoopbackSocket.Send(socket, """{"event":"presence_state","payload":{},"ref":null,"topic":"realtime:memorynotes"}""");
        await LoopbackSocket.Send(socket, """{"event":"postgres_changes","payload":{"data":{"table":"notes","type":"UPDATE"}},"ref":null,"topic":"realtime:memorynotes"}""");
        Assert.True(await changes.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(0, changes.CurrentCount);

        // A refreshed token goes to the channel.
        realtime.Update("token-2");
        var update = await LoopbackSocket.Receive(socket);
        Assert.Equal("access_token", (string?)update["event"]);
        Assert.Equal("token-2", (string?)update["payload"]!["access_token"]);

        // Dropped (the PC slept, the network changed): back after a pause, with the newer token.
        socket.Abort();
        var again = (await server.Accept())!;
        Assert.Equal("token-2", (string?)(await LoopbackSocket.Receive(again))["payload"]!["access_token"]);

        // Disconnected on purpose (signed out): it stays away.
        realtime.Disconnect();
        Assert.Null(await server.Accept(TimeSpan.FromMilliseconds(500)));
    }
}

/// A WebSocket server on the loopback address, standing in for Supabase Realtime.
sealed class LoopbackSocket : IDisposable
{
    readonly TcpListener listener = new(IPAddress.Loopback, 0);

    public LoopbackSocket() => listener.Start();

    public Uri Url => new($"ws://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}/realtime/v1/websocket?apikey=test&vsn=1.0.0");
    public string? RequestLine { get; private set; }

    /// The next client, after the handshake; null if none comes within `wait`.
    public async Task<WebSocket?> Accept(TimeSpan? wait = null)
    {
        using var timeout = new CancellationTokenSource(wait ?? TimeSpan.FromSeconds(10));
        TcpClient client;
        try { client = await listener.AcceptTcpClientAsync(timeout.Token); }
        catch (OperationCanceledException) { return null; }
        var stream = client.GetStream();
        var head = new StringBuilder();
        while (!head.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal))
            head.Append((char)(stream.ReadByte() is var b and >= 0 ? b : throw new IOException("The client left during the handshake.")));
        var lines = head.ToString().Split("\r\n");
        RequestLine = lines[0];
        var key = lines.Single(l => l.StartsWith("Sec-WebSocket-Key:", StringComparison.OrdinalIgnoreCase))["Sec-WebSocket-Key:".Length..].Trim();
        var accept = Convert.ToBase64String(SHA1.HashData(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
        await stream.WriteAsync(Encoding.ASCII.GetBytes(
            $"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"));
        return WebSocket.CreateFromStream(stream, new WebSocketCreationOptions { IsServer = true });
    }

    public static async Task<JsonObject> Receive(WebSocket socket)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var buffer = new byte[64 * 1024];
        using var message = new MemoryStream();
        ValueWebSocketReceiveResult part;
        do
        {
            part = await socket.ReceiveAsync(buffer.AsMemory(), timeout.Token);
            message.Write(buffer, 0, part.Count);
        } while (!part.EndOfMessage);
        return JsonNode.Parse(message.ToArray())!.AsObject();
    }

    public static Task Send(WebSocket socket, string text) =>
        socket.SendAsync(new ArraySegment<byte>(Encoding.UTF8.GetBytes(text)), WebSocketMessageType.Text, true, CancellationToken.None);

    public void Dispose() => listener.Stop();
}
