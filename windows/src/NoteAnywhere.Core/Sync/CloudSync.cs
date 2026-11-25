using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using NoteAnywhere.Core.Crypto;

namespace NoteAnywhere.Core.Sync;

/// Optional sync through Supabase, a port of SyncCloud.swift (D31, D39). Each device keeps its own database: rows edited
/// here are pushed, rows other devices pushed are pulled by `seq`, and the server keeps the newer edit. Syncing needs an
/// account and the vault key, so nothing goes up unencrypted. Changed is raised, on any thread, whenever what Settings ▸
/// Sync shows may have changed.
public sealed class CloudSync
{
    public static readonly Uri ProjectUrl = new("https://strhaqnvxtpmlvcwkkne.supabase.co/");
    /// Publishable (anon) key: meant to ship in apps; row level security keeps each account's notes to itself.
    public const string PublishableKey = "sb_publishable_9GowTlVr_z6p3W1d2W-28g_M0Ke1Mzv";
    /// Where sign-in links land; allowed in supabase/config.toml and registered as the apps' URL scheme.
    public const string Callback = "memorynotes://auth-callback";
    /// Google sign-in through Supabase: it redirects back to Callback with the session, like the email link.
    public static readonly string GoogleUrl = $"{ProjectUrl}auth/v1/authorize?provider=google&redirect_to={Uri.EscapeDataString(Callback)}";
    internal static readonly Uri RealtimeUrl = new($"wss://{ProjectUrl.Host}/realtime/v1/websocket?apikey={PublishableKey}&vsn=1.0.0");

    public enum VaultStep { Create, Enter, Ready }

    /// What went wrong, worded to be shown as it is.
    public sealed class Failure(string message, int status = 0) : Exception(message)
    {
        public int Status { get; } = status;
    }

    /// Signed in as.
    public string? Email => Session?.Email;
    /// A sign-in link and code were sent here.
    public string? PendingEmail { get; private set { field = value; Changed?.Invoke(); } }
    public DateTimeOffset? LastSynced { get; private set { field = value; Changed?.Invoke(); } }
    public bool Busy { get; private set { field = value; Changed?.Invoke(); } }
    public string? Error { get; set { field = value; Changed?.Invoke(); } }
    /// End-to-end encryption, after signing in: null until known, then create or enter the passphrase, then ready.
    public VaultStep? Vault { get; private set { field = value; Changed?.Invoke(); } }
    public bool Active => Session != null && vaultKey != null;
    public event Action? Changed;

    static readonly JsonSerializerOptions Columns = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };

    readonly ISecretStore secrets;
    readonly HttpClient http;
    readonly Realtime realtime = new();
    readonly Lock gate = new();
    readonly SemaphoreSlim refreshing = new(1, 1);  // a refresh token works once
    byte[]? vaultKey;
    (Uri Realtime, TimeSpan Every, TimeSpan AfterSave)? live;
    NoteStoreWatcher? watcher;
    Timer? timer;
    CancellationTokenSource? pushSoon;
    Task? round;
    bool? rerun;  // null: none; false: push only; true: push and pull

    Session? Session { get; set { field = value; Changed?.Invoke(); } }

    public CloudSync(ISecretStore secrets, HttpMessageHandler? handler = null)
    {
        this.secrets = secrets;
        http = new HttpClient(handler ?? new SocketsHttpHandler()) { BaseAddress = ProjectUrl, Timeout = Timeout.InfiniteTimeSpan };
        Session = Saved(secrets.Get("session"));
        vaultKey = Session is { } s ? SyncVault.SavedKey(secrets, s.UserID) : null;
        Vault = vaultKey != null ? VaultStep.Ready : null;
        realtime.Changed += SyncNow;
    }

    static Session? Saved(byte[]? saved)
    {
        try { return saved is null ? null : Session.From(JsonNode.Parse(saved)); }
        catch (Exception e) when (e is JsonException or Failure) { return null; }  // unreadable: signed out, as the Mac's try?
    }

    /// At launch: syncs if this device is signed in with the vault key; signed in without it, finds out which passphrase step is next.
    public void Start() => Start(RealtimeUrl, TimeSpan.FromSeconds(60), TimeSpan.FromSeconds(2));

    internal void Start(Uri realtimeUrl, TimeSpan every, TimeSpan afterSave)
    {
        live = (realtimeUrl, every, afterSave);
        Restart();
        if (Session != null && vaultKey == null) _ = Perform(CheckVault);
    }

    /// The Mac's modeChanged(): stops, then, if syncing can run, pushes 2 s after any save (this app's, the browser
    /// host's, the MCP server's), runs a full round every 60 s and when Realtime reports a change, and one now.
    void Restart()
    {
        Stop();
        if (!Active || live is not { } l) return;
        lock (gate)
        {
            watcher = new NoteStoreWatcher();
            watcher.Changed += () => { if (SomethingToPush()) PushSoon(l.AfterSave); };
            timer = new Timer(_ => SyncNow(), null, l.Every, l.Every);
        }
        _ = ConnectRealtime(l.Realtime);
        SyncNow();
    }

    void Stop()
    {
        lock (gate)
        {
            watcher?.Dispose();
            watcher = null;
            timer?.Dispose();
            timer = null;
        }
        Interlocked.Exchange(ref pushSoon, null)?.Cancel();
        realtime.Disconnect();
    }

    // Unlike the Mac's notification, the watcher also sees sync's own writes (cursors, rows marked clean): a round for
    // those would push nothing and only clear the error the last round showed.
    static bool SomethingToPush() => NoteStore.DirtyFolders().Count > 0 || NoteStore.DirtyNotes(1).Count > 0
        || NoteStore.DirtySnapshots(1).Count > 0 || NoteStore.DirtyImages(1).Count > 0;

    void PushSoon(TimeSpan delay)
    {
        var mine = new CancellationTokenSource();
        Interlocked.Exchange(ref pushSoon, mine)?.Cancel();
        Task.Delay(delay, mine.Token).ContinueWith(_ => Sync(pull: false), mine.Token, TaskContinuationOptions.OnlyOnRanToCompletion, TaskScheduler.Default);
    }

    async Task ConnectRealtime(Uri url)
    {
        try
        {
            var token = await AccessToken();
            if (Active) realtime.Connect(url, token);
        }
        catch (Exception)
        {
            // As the Mac's try?: a token that can't be had shows in the round that follows.
        }
    }

    // Sign in by email: a link that opens the app, or the code the email carries

    public Task SendLink(string address) => Perform(async () =>
    {
        var email = address.Trim().ToLowerInvariant();
        await Auth("otp", new { email, create_user = true }, "redirect_to=" + Uri.EscapeDataString(Callback));
        PendingEmail = email;
    });

    public Task Verify(string code) => PendingEmail is not { } email ? Task.CompletedTask : Perform(async () =>
        await SignedIn(await Auth("verify", new { type = "email", email, token = string.Concat(code.Where(char.IsDigit)) })));

    /// The sign-in link's redirect, from the email or Google: memorynotes://auth-callback#access_token=…&refresh_token=…&expires_at=…
    public Task Handle(string url)
    {
        if (!url.StartsWith(Callback, StringComparison.Ordinal)) return Task.CompletedTask;
        var fields = Fields(url);
        return Perform(async () =>
        {
            if (fields.GetValueOrDefault("error_description") is { } problem) throw new Failure(problem.Replace('+', ' '));
            if (fields.GetValueOrDefault("access_token") is not { } access || fields.GetValueOrDefault("refresh_token") is not { } refresh)
                throw new Failure("That sign-in link didn't work. Send a new one.");
            var request = new HttpRequestMessage(HttpMethod.Get, "auth/v1/user");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", access);
            var user = JsonNode.Parse(await Send(request));
            await SignedIn(new JsonObject
            {
                ["access_token"] = access, ["refresh_token"] = refresh, ["user"] = user,
                ["expires_at"] = Number(fields.GetValueOrDefault("expires_at")), ["expires_in"] = Number(fields.GetValueOrDefault("expires_in")),
            });
        });
    }

    /// The fragment's fields, then the query's (where Supabase puts an error).
    static Dictionary<string, string> Fields(string url)
    {
        var hash = url.IndexOf('#');
        var front = hash < 0 ? url : url[..hash];
        var question = front.IndexOf('?');
        Dictionary<string, string> fields = [];
        foreach (var part in new[] { hash < 0 ? "" : url[(hash + 1)..], question < 0 ? "" : front[(question + 1)..] })
            foreach (var pair in part.Split('&'))
                if (pair.IndexOf('=') is var eq and > 0)
                    fields[Uri.UnescapeDataString(pair[..eq])] = Uri.UnescapeDataString(pair[(eq + 1)..]);
        return fields;
    }

    static double? Number(string? text) => double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var number) ? number : null;

    async Task SignedIn(JsonNode? reply)
    {
        var session = Session.From(reply);
        if (NoteStore.SyncValue("user") != session.UserID)
        {
            NoteStore.ResetSync();  // another account: send it everything, fetch all of its notes
            NoteStore.SetSyncValue("user", session.UserID);
        }
        secrets.Set("session", session.Saved());
        Session = session;
        PendingEmail = null;
        vaultKey = SyncVault.SavedKey(secrets, session.UserID);
        Vault = vaultKey != null ? VaultStep.Ready : null;
        Restart();
        if (vaultKey == null) await CheckVault();
    }

    public void CancelCode() => PendingEmail = null;

    /// Stops syncing and forgets the account on this device; notes stay here.
    public void SignOut()
    {
        Stop();
        if (Session?.UserID is { } id) SyncVault.DeleteKey(secrets, id);
        secrets.Delete("session");
        Session = null;
        vaultKey = null;
        Vault = null;
        LastSynced = null;
    }

    // End-to-end encryption

    /// Is there a vault for this account yet (another device made it), or is this the first device?
    async Task CheckVault() =>
        Vault = JsonNode.Parse(await Rest("vaults?select=salt,wrapped", HttpMethod.Get)) is JsonArray { Count: > 0 } ? VaultStep.Enter : VaultStep.Create;

    /// First device: a random vault key, stored on the server only wrapped by the passphrase.
    public Task CreateVault(string passphrase) => Perform(async () =>
    {
        var (key, salt, wrapped) = await Task.Run(() => SyncVault.CreateKey(passphrase));
        // A plain insert: if another device just made the vault, this fails rather than replacing its key.
        try
        {
            await Rest("vaults", HttpMethod.Post, new[] { new { salt, wrapped } }, upsert: false);
        }
        catch (Failure e) when (e.Status == 409)
        {
            Vault = VaultStep.Enter;
            throw new Failure("Another device already set a sync passphrase. Enter that one.");
        }
        Unlocked(key);
    });

    /// Any other device: unwrap the vault key with the passphrase.
    public Task EnterVault(string passphrase) => Perform(async () =>
    {
        var row = JsonNode.Parse(await Rest("vaults?select=salt,wrapped", HttpMethod.Get)) is JsonArray { Count: > 0 } rows ? rows[0] as JsonObject : null;
        if (Session.Text(row?["salt"]) is not { } salt || Session.Text(row?["wrapped"]) is not { } wrapped) throw new Failure("No vault yet.");
        Unlocked(await Task.Run(() => SyncVault.UnwrapKey(passphrase, salt, wrapped)));
    });

    void Unlocked(byte[] key)
    {
        if (Session?.UserID is not { } id) return;
        SyncVault.SaveKey(secrets, id, key);
        vaultKey = key;
        Vault = VaultStep.Ready;
        Restart();
    }

    // Sync

    public void SyncNow() => _ = Sync(pull: true);

    /// A round: this device's edits up, then (unless only pushing) everyone else's down. Rounds don't overlap: one asked
    /// for meanwhile runs once that one is done, and the task ends with it.
    public Task Sync(bool pull)
    {
        lock (gate)
        {
            if (!Active) return Task.CompletedTask;
            if (round != null)
            {
                rerun = (rerun ?? false) || pull;
                return round;
            }
            return round = Task.Run(() => Rounds(pull));
        }
    }

    /// The round running now, if any, with the ones queued behind it.
    internal Task Running
    {
        get { lock (gate) return round ?? Task.CompletedTask; }
    }

    async Task Rounds(bool pull)
    {
        for (bool? next = pull; next is { } now;)
        {
            await Perform(() => Round(now), showBusy: now);
            lock (gate)
            {
                next = Active ? rerun : null;
                rerun = null;
                if (next == null) round = null;
            }
        }
    }

    async Task Round(bool pull)
    {
        // Images go up before the notes that show them, but a failing image (say the server isn't set up for them yet)
        // mustn't hold up notes: it's reported after they're through.
        Exception? imageError = null;
        try { await PushImages(); } catch (Exception e) { imageError = e; }
        await Push();
        if (pull)
        {
            await Pull();
            try { await PullImages(); } catch (Exception e) { imageError ??= e; }
        }
        LastSynced = DateTimeOffset.Now;
        if (imageError != null) throw new Failure($"Images didn't sync: {imageError.Message}");
    }

    async Task Push()
    {
        if (vaultKey is not { } key) return;
        var folders = NoteStore.DirtyFolders();  // first: notes point at them
        if (folders.Count > 0)
        {
            await Rest("folders?on_conflict=id", HttpMethod.Post, folders.Select(f => f.Row(key)).ToList());
            NoteStore.MarkPushed(folders: folders);
        }
        while (true)
        {
            var notes = NoteStore.DirtyNotes();
            if (notes.Count > 0)
            {
                await Rest("notes?on_conflict=id", HttpMethod.Post, notes.Select(n => n.Row(key)).ToList());
                NoteStore.MarkPushed(notes: notes);
            }
            // Snapshots reference notes, so they go up after them.
            var snapshots = NoteStore.DirtySnapshots();
            if (snapshots.Count > 0)
            {
                await Rest("snapshots?on_conflict=note_id,day", HttpMethod.Post, snapshots.Select(s => s.Row(key)).ToList());
                NoteStore.MarkPushed(snapshots: snapshots);
            }
            if (notes.Count < 200 && snapshots.Count < 500) return;
        }
    }

    // shortcut: a row committed out of seq order by a concurrent writer could be skipped until it changes again;
    // fine for one person's devices, switch to a server-side "changes since" function if that ever matters.
    async Task<List<T>> Page<T>(string table, string columns)
    {
        var cursor = NoteStore.SyncValue($"cursor.{table}") ?? "0";
        var data = await Rest($"{table}?select={columns},seq&seq=gt.{cursor}&order=seq.asc&limit=500", HttpMethod.Get);
        return JsonSerializer.Deserialize<List<T>>(data, Columns) ?? [];
    }

    async Task Pull()
    {
        if (vaultKey is not { } key) return;
        while (true)
        {
            var folders = await Page<NoteStore.CloudFolder>("folders", "id,name,updated_at,deleted_at");
            var notes = await Page<NoteStore.CloudNote>("notes", "id,kind,target,label,body_md,created_at,updated_at,deleted_at,pinned,folder_id,color,locked,starred");
            var snapshots = await Page<NoteStore.CloudSnapshot>("snapshots", "note_id,day,body_md,updated_at");
            NoteStore.ApplyRemote([.. notes.Select(n => n.Opened(key))], [.. snapshots.Select(s => s.Opened(key))], [.. folders.Select(f => f.Opened(key))]);
            if (folders.LastOrDefault()?.Seq is { } f) NoteStore.SetSyncValue("cursor.folders", f.ToString(CultureInfo.InvariantCulture));
            if (notes.LastOrDefault()?.Seq is { } n) NoteStore.SetSyncValue("cursor.notes", n.ToString(CultureInfo.InvariantCulture));
            if (snapshots.LastOrDefault()?.Seq is { } s) NoteStore.SetSyncValue("cursor.snapshots", s.ToString(CultureInfo.InvariantCulture));
            if (notes.Count < 500 && snapshots.Count < 500 && folders.Count < 500) return;
        }
    }

    /// Image bytes, sealed with the vault key, go to Storage under the account's folder; then the row says they're there.
    async Task PushImages()
    {
        if (vaultKey is not { } key || Session?.UserID is not { } user) return;
        while (true)
        {
            var images = NoteStore.DirtyImages();
            foreach (var image in images)
            {
                var bytes = NoteStore.Image(image.Id)?.Data ?? throw new Failure($"Image {image.Id} is missing from this device.");
                await Storage($"{user}/{image.Id}", SyncVault.Seal(bytes, key));
            }
            if (images.Count > 0)
            {
                await Rest("images?on_conflict=id", HttpMethod.Post, images.Select(i => i.Row()).ToList());
                NoteStore.MarkPushed(images: images);
            }
            if (images.Count < 50) return;
        }
    }

    /// New image rows from other devices; each one's bytes are downloaded and written before the cursor moves past it.
    async Task PullImages()
    {
        if (vaultKey is not { } key || Session?.UserID is not { } user) return;
        while (true)
        {
            var images = await Page<NoteStore.CloudImage>("images", "id,type,created_at");
            foreach (var image in images.Where(NoteStore.WantsImage))
                NoteStore.SaveRemoteImage(image, SyncVault.Open(await Storage($"{user}/{image.Id}"), key));
            if (images.LastOrDefault()?.Seq is { } last) NoteStore.SetSyncValue("cursor.images", last.ToString(CultureInfo.InvariantCulture));
            if (images.Count < 500) return;
        }
    }

    async Task Perform(Func<Task> work, bool showBusy = true)
    {
        if (showBusy) Busy = true;
        try
        {
            await work();
            Error = null;
        }
        catch (Exception e)
        {
            Error = e.Message;
        }
        finally
        {
            if (showBusy) Busy = false;
        }
    }

    // HTTP

    async Task<JsonNode?> Auth(string path, object body, string query = "")
    {
        var request = new HttpRequestMessage(HttpMethod.Post, $"auth/v1/{path}" + (query.Length == 0 ? "" : "?" + query)) { Content = Json(body) };
        var data = await Send(request);
        try { return JsonNode.Parse(data); }
        catch (JsonException) { return null; }
    }

    async Task<byte[]> Rest(string path, HttpMethod method, object? body = null, bool upsert = true)
    {
        var request = new HttpRequestMessage(method, "rest/v1/" + path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await AccessToken());
        if (body != null)
        {
            request.Content = Json(body);
            request.Headers.Add("Prefer", upsert ? "resolution=merge-duplicates,return=minimal" : "return=minimal");
        }
        return await Send(request);
    }

    /// One image's sealed bytes in the private "images" bucket: uploads (replacing) with `upload`, downloads without.
    async Task<byte[]> Storage(string path, byte[]? upload = null)
    {
        var request = new HttpRequestMessage(upload is null ? HttpMethod.Get : HttpMethod.Post,
            (upload is null ? "storage/v1/object/authenticated/images/" : "storage/v1/object/images/") + path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await AccessToken());
        if (upload != null)
        {
            request.Content = new ByteArrayContent(upload) { Headers = { ContentType = new MediaTypeHeaderValue("application/octet-stream") } };
            request.Headers.Add("x-upsert", "true");
        }
        // URLSession's 30 s is a limit on waiting, not on a whole transfer, and an image of 20 MB can take longer.
        return await Send(request, TimeSpan.FromMinutes(5));
    }

    static StringContent Json(object body) => new(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");

    async Task<byte[]> Send(HttpRequestMessage request, TimeSpan? limit = null)
    {
        using var _ = request;
        request.Headers.Add("apikey", PublishableKey);
        using var timeout = new CancellationTokenSource(limit ?? TimeSpan.FromSeconds(30));
        int status;
        byte[] data;
        try
        {
            using var response = await http.SendAsync(request, timeout.Token);
            status = (int)response.StatusCode;
            data = await response.Content.ReadAsByteArrayAsync(timeout.Token);
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested)
        {
            throw new Failure("The request timed out.");
        }
        if (status is >= 200 and < 300) return data;
        var message = Message(data);
        if (status is 401 or 403 && message?.Contains("JWT", StringComparison.Ordinal) == true)
        {
            Session = null;
            secrets.Delete("session");
        }
        throw new Failure(message ?? $"The sync server answered {status}.", status);
    }

    static string? Message(byte[] data)
    {
        try
        {
            var json = JsonNode.Parse(data) as JsonObject;
            return new[] { "msg", "message", "error_description", "error" }.Select(name => Session.Text(json?[name])).FirstOrDefault(text => text != null);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// A valid access token, refreshed a minute before it expires.
    async Task<string> AccessToken()
    {
        await refreshing.WaitAsync();
        try
        {
            var session = Session ?? throw new Failure("Sign in to sync.");
            if (session.ExpiresAt - 60 < DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0)
            {
                var fresh = Session.From(await Auth("token", new { refresh_token = session.RefreshToken }, "grant_type=refresh_token"));
                if (Session != session) throw new Failure("Sign in to sync.");  // signed out meanwhile: don't bring the session back
                secrets.Set("session", fresh.Saved());
                Session = session = fresh;
                realtime.Update(session.AccessToken);
            }
            return session.AccessToken;
        }
        finally
        {
            refreshing.Release();
        }
    }
}
