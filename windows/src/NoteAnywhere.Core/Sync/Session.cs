using System.Text;
using System.Text.Json.Nodes;

namespace NoteAnywhere.Core.Sync;

/// The account signed in on this device. Read from Supabase Auth's reply ({access_token, refresh_token, expires_at or
/// expires_in, user}) and kept, in the same shape, in the secret store: never in the notes database.
sealed record Session(string AccessToken, string RefreshToken, double ExpiresAt, string UserID, string Email)
{
    public static Session From(JsonNode? reply)
    {
        var json = reply as JsonObject;
        var user = json?["user"] as JsonObject;
        if (Text(json?["access_token"]) is not { } access || Text(json?["refresh_token"]) is not { } refresh || Text(user?["id"]) is not { } id)
            throw new CloudSync.Failure("That code didn't work. Check it, or send a new one.");
        var expiresAt = Number(json!["expires_at"]) ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0 + (Number(json["expires_in"]) ?? 3600);
        return new(access, refresh, expiresAt, id, Text(user!["email"]) ?? "");
    }

    public byte[] Saved() => Encoding.UTF8.GetBytes(new JsonObject
    {
        ["access_token"] = AccessToken, ["refresh_token"] = RefreshToken, ["expires_at"] = ExpiresAt,
        ["user"] = new JsonObject { ["id"] = UserID, ["email"] = Email },
    }.ToJsonString());

    public override string ToString() => $"Session({UserID})";  // never the tokens, wherever it's printed

    internal static string? Text(JsonNode? node) => node is JsonValue value && value.TryGetValue(out string? text) ? text : null;

    static double? Number(JsonNode? node) => node is JsonValue value && value.TryGetValue(out double number) ? number : null;
}
