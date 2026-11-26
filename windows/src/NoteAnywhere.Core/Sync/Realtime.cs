using System.Globalization;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;

namespace NoteAnywhere.Core.Sync;

/// Supabase Realtime over a plain WebSocket (the Phoenix protocol), as on the Mac: any change to this account's notes or
/// folders raises Changed, and sync pulls.
sealed class Realtime
{
    const string Topic = "realtime:memorynotes";

    public event Action? Changed;
    internal TimeSpan RetryAfter { get; init; } = TimeSpan.FromSeconds(10);

    readonly Lock gate = new();
    readonly SemaphoreSlim sending = new(1, 1);  // a WebSocket takes one send at a time
    ClientWebSocket? socket;
    Timer? heartbeat;
    string? token;
    int sent;

    public void Connect(Uri url, string token)
    {
        Disconnect();
        var socket = new ClientWebSocket();
        lock (gate) (this.socket, this.token) = (socket, token);
        _ = Run(socket, url, token);
    }

    /// A refreshed access token, for the channel to keep its rights.
    public void Update(string token)
    {
        ClientWebSocket? now;
        lock (gate) (now, this.token) = (socket, token);
        _ = Send(now, Topic, "access_token", new JsonObject { ["access_token"] = token });
    }

    public void Disconnect()
    {
        ClientWebSocket? old;
        lock (gate)
        {
            (old, socket) = (socket, null);
            heartbeat?.Dispose();
            heartbeat = null;
        }
        old?.Abort();
        old?.Dispose();
    }

    async Task Run(ClientWebSocket socket, Uri url, string token)
    {
        try
        {
            await socket.ConnectAsync(url, CancellationToken.None);
            await Send(socket, Topic, "phx_join", new JsonObject
            {
                ["config"] = new JsonObject { ["postgres_changes"] = new JsonArray(Table("notes"), Table("folders")) },
                ["access_token"] = token,
            });
            lock (gate)
            {
                if (this.socket == socket)
                    heartbeat = new Timer(_ => _ = Send(socket, "phoenix", "heartbeat", []), null, TimeSpan.FromSeconds(25), TimeSpan.FromSeconds(25));
            }
            var buffer = new byte[16 * 1024];
            using var message = new MemoryStream();
            while (true)
            {
                var part = await socket.ReceiveAsync(buffer.AsMemory(), CancellationToken.None);
                if (part.MessageType == WebSocketMessageType.Close) throw new WebSocketException(WebSocketError.ConnectionClosedPrematurely);
                message.Write(buffer, 0, part.Count);
                if (!part.EndOfMessage) continue;
                // As the Mac: the join's reply names postgres_changes too, so every (re)connect also pulls once.
                if (part.MessageType == WebSocketMessageType.Text
                    && Encoding.UTF8.GetString(message.GetBuffer(), 0, (int)message.Length).Contains("\"postgres_changes\"", StringComparison.Ordinal))
                    Changed?.Invoke();
                message.SetLength(0);
            }
        }
        catch (Exception)
        {
            // Dropped (sleep, network change): reconnect after a pause; the 60 s timer covers the gap.
            await Task.Delay(RetryAfter);
            string? again;
            lock (gate) again = this.socket == socket ? this.token : null;
            if (again != null) Connect(url, again);
        }
    }

    static JsonObject Table(string name) => new() { ["event"] = "*", ["schema"] = "public", ["table"] = name };

    async Task Send(ClientWebSocket? socket, string topic, string @event, JsonObject payload)
    {
        if (socket == null) return;
        var reference = Interlocked.Increment(ref sent).ToString(CultureInfo.InvariantCulture);
        var text = new JsonObject { ["topic"] = topic, ["event"] = @event, ["payload"] = payload, ["ref"] = reference }.ToJsonString();
        await sending.WaitAsync();
        try
        {
            await socket.SendAsync(Encoding.UTF8.GetBytes(text).AsMemory(), WebSocketMessageType.Text, true, CancellationToken.None);
        }
        catch (Exception e) when (e is WebSocketException or InvalidOperationException or ObjectDisposedException or OperationCanceledException)
        {
            // Not sent, as on the Mac: a dropped socket shows in the receive loop, which reconnects.
        }
        finally
        {
            sending.Release();
        }
    }
}
