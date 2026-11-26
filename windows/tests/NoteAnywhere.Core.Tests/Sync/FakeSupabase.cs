using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using NoteAnywhere.Core.Sync;

namespace NoteAnywhere.Core.Tests.Sync;

/// Supabase as the apps reach it (Auth, PostgREST, Storage), in memory, so no test ever calls the real project. Its
/// tables keep the server's rules (sync_accept in supabase/migrations): an update older than the stored row is dropped,
/// a deleted note or folder stays deleted, and every accepted write takes the next seq. Every request is kept.
sealed class FakeSupabase : HttpMessageHandler
{
    public const string Code = "12345678";
    public string UserID { get; } = Guid.NewGuid().ToString();
    public string Email => "ada@example.com";
    /// The next request whose "METHOD /path" starts with a key gets that answer instead, once.
    public Dictionary<string, (int Status, string Json)> Failures { get; } = [];
    /// Awaited before each answer: a round held open.
    public Func<Task>? Hold { get; set; }
    public long Seq { get; private set; }

    readonly Lock gate = new();
    readonly List<Request> requests = [];
    readonly Dictionary<string, List<JsonObject>> tables = new() { ["notes"] = [], ["folders"] = [], ["snapshots"] = [], ["images"] = [], ["vaults"] = [] };
    readonly Dictionary<string, byte[]> files = [];
    int sessions;

    public string AccessToken => $"access-{sessions}";
    string RefreshToken => $"refresh-{sessions}";

    public sealed record Request(string Method, string Path, string Query, Dictionary<string, string> Headers, byte[] Body)
    {
        public string Text => Encoding.UTF8.GetString(Body);
        public JsonNode? Json => JsonNode.Parse(Body);
        public override string ToString() => $"{Method} {Path}{Query}";
    }

    public List<Request> Requests { get { lock (gate) return [.. requests]; } }
    public void ClearRequests() { lock (gate) requests.Clear(); }
    public List<JsonObject> Rows(string table) { lock (gate) return [.. tables[table]]; }
    public JsonObject Row(string table, string id) => Rows(table).Single(row => (string?)row["id"] == id);
    public bool Has(string table, string id) => Rows(table).Any(row => (string?)row["id"] == id);
    public void PutFile(string name, byte[] data) { lock (gate) files[name] = data; }

    /// A row another device pushed, through the same rules.
    public void Put(string table, JsonObject row)
    {
        lock (gate) Upsert(table, JsonNode.Parse(row.ToJsonString())!.AsObject(), merge: true);
    }

    /// A new session for this account, as Auth hands out after a code, a link or a refresh.
    public JsonObject Issue()
    {
        lock (gate)
        {
            sessions++;
            return new JsonObject
            {
                ["access_token"] = AccessToken, ["token_type"] = "bearer", ["expires_in"] = 3600,
                ["expires_at"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600, ["refresh_token"] = RefreshToken, ["user"] = User(),
            };
        }
    }

    JsonObject User() => new() { ["id"] = UserID, ["aud"] = "authenticated", ["role"] = "authenticated", ["email"] = Email };

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage message, CancellationToken cancel)
    {
        var body = message.Content is null ? [] : await message.Content.ReadAsByteArrayAsync(cancel);
        IEnumerable<KeyValuePair<string, IEnumerable<string>>> headers = message.Content is null ? message.Headers : message.Headers.Concat(message.Content.Headers);
        var request = new Request(message.Method.Method, message.RequestUri!.AbsolutePath, message.RequestUri.Query,
            headers.ToDictionary(h => h.Key, h => string.Join(",", h.Value), StringComparer.OrdinalIgnoreCase), body);
        lock (gate) requests.Add(request);
        if (Hold is { } hold) await hold();
        lock (gate) return Answer(request);
    }

    HttpResponseMessage Answer(Request r)
    {
        if (r.Headers.GetValueOrDefault("apikey") != CloudSync.PublishableKey) return Reply(401, """{"message":"No API key found in request"}""");
        if (Failures.Keys.FirstOrDefault(key => r.ToString().StartsWith(key, StringComparison.Ordinal)) is { } failing)
        {
            var (status, text) = Failures[failing];
            Failures.Remove(failing);
            return Reply(status, text);
        }
        var json = r.Headers.GetValueOrDefault("Content-Type")?.StartsWith("application/json", StringComparison.Ordinal) == true ? JsonNode.Parse(r.Body) : null;
        var bearer = r.Headers.GetValueOrDefault("Authorization") == $"Bearer {AccessToken}";
        switch (r.ToString())
        {
            case "POST /auth/v1/otp?redirect_to=memorynotes%3A%2F%2Fauth-callback":
                return Reply(200, "{}");
            case "POST /auth/v1/verify":
                return (string?)json?["email"] == Email && (string?)json?["token"] == Code && (string?)json?["type"] == "email"
                    ? Reply(200, Issue().ToJsonString())
                    : Reply(403, """{"code":403,"error_code":"otp_expired","msg":"Token has expired or is invalid"}""");
            case "POST /auth/v1/token?grant_type=refresh_token":
                return (string?)json?["refresh_token"] == RefreshToken
                    ? Reply(200, Issue().ToJsonString())
                    : Reply(400, """{"code":400,"error_code":"refresh_token_not_found","msg":"Invalid Refresh Token: Refresh Token Not Found"}""");
            case "GET /auth/v1/user":
                return bearer ? Reply(200, User().ToJsonString()) : Reply(403, """{"code":403,"error_code":"bad_jwt","msg":"invalid JWT: unable to parse or verify signature"}""");
        }
        if (!bearer) return Reply(401, """{"code":"PGRST303","details":null,"hint":null,"message":"JWT expired"}""");
        if (r.Path.StartsWith("/rest/v1/", StringComparison.Ordinal)) return Rest(r, r.Path["/rest/v1/".Length..], json);
        const string upload = "/storage/v1/object/images/", download = "/storage/v1/object/authenticated/images/";
        if (r.Method == "POST" && r.Path.StartsWith(upload, StringComparison.Ordinal))
        {
            var name = r.Path[upload.Length..];
            if (!name.StartsWith(UserID + "/", StringComparison.Ordinal))  // each account's own folder only
                return Reply(400, """{"statusCode":"403","error":"Unauthorized","message":"new row violates row-level security policy"}""");
            files[name] = r.Body;
            return Reply(200, new JsonObject { ["Key"] = "images/" + name }.ToJsonString());
        }
        if (r.Method == "GET" && r.Path.StartsWith(download, StringComparison.Ordinal))
            return files.TryGetValue(r.Path[download.Length..], out var file)
                ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(file) }
                : Reply(404, """{"statusCode":"404","error":"not_found","message":"Object not found"}""");
        return Reply(404, "{}");
    }

    HttpResponseMessage Rest(Request r, string table, JsonNode? body)
    {
        var query = r.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries).Select(pair => pair.Split('=', 2))
            .ToDictionary(pair => pair[0], pair => Uri.UnescapeDataString(pair[1]));
        if (r.Method == "GET")
        {
            var columns = query["select"].Split(',');
            var after = query.TryGetValue("seq", out var seq) ? long.Parse(seq["gt.".Length..]) : long.MinValue;
            var limit = query.TryGetValue("limit", out var most) ? int.Parse(most) : int.MaxValue;
            var rows = table == "vaults" ? tables[table] : tables[table].Where(row => (long)row["seq"]! > after).OrderBy(row => (long)row["seq"]!).Take(limit);
            return Reply(200, new JsonArray([.. rows.Select(row => new JsonObject(columns.Select(c => KeyValuePair.Create(c, row[c]?.DeepClone()))))]).ToJsonString());
        }
        var merge = r.Headers.GetValueOrDefault("Prefer")?.Contains("resolution=merge-duplicates", StringComparison.Ordinal) == true;
        foreach (var row in body!.AsArray())
            if (!Upsert(table, row!.AsObject().DeepClone().AsObject(), merge, query.GetValueOrDefault("on_conflict")))
                return Reply(409, """{"code":"23505","details":"Key already exists.","hint":null,"message":"duplicate key value violates unique constraint \"vaults_pkey\""}""");
        return Reply(201, "");
    }

    /// The table's primary key decides insert or update; an update follows sync_accept. False: a duplicate, not merged.
    bool Upsert(string table, JsonObject row, bool merge, string? onConflict = null)
    {
        row["user_id"] = UserID;
        var keys = (onConflict ?? (table == "vaults" ? "user_id" : table == "snapshots" ? "note_id,day" : "id")).Split(',');
        var old = tables[table].FirstOrDefault(o => keys.All(k => JsonNode.DeepEquals(o[k], row[k])));
        if (old is null)
        {
            if (table != "vaults") row["seq"] = ++Seq;
            tables[table].Add(row);
            return true;
        }
        if (!merge) return false;
        if (table != "images")  // images' trigger runs on insert only: they never change
        {
            if ((double)row["updated_at"]! < (double)old["updated_at"]!) return true;
            if (table is "notes" or "folders" && old["deleted_at"] is not null) row["deleted_at"] = old["deleted_at"]!.DeepClone();
            row["seq"] = ++Seq;
        }
        foreach (var (column, value) in row) old[column] = value?.DeepClone();
        return true;
    }

    static HttpResponseMessage Reply(int status, string json) =>
        new((HttpStatusCode)status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
}
