using System.Net;
using System.Text.Encodings.Web;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using NoteAnywhere.Core.Search;

namespace NoteAnywhere.Core;

/// The browsers' native messaging host, a port of the Mac's NativeHost.swift: the extension lists, saves and searches
/// website notes through it, keeps pictures in it, and holds one connection open to hear of every change. Browsers start
/// it on demand, so the extension works while the app is closed. `toPng` and `writingModel` come from the app (WPF's
/// decoders, the downloaded model); `http` and `settings` are for tests.
public sealed class NativeHost(IWritingModel? writingModel = null, Func<byte[], byte[]>? toPng = null, HttpClient? http = null,
    Func<Settings>? settings = null)
{
    /// Image bytes per reply: their base64 stays under Chrome's 1 MB cap on what a host sends back.
    public const int ImagePiece = 600_000;

    static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,  // text as UTF-8, not \u escapes, so replies stay small under that cap
    };
    static readonly byte[] ChangedEvent = """{"ok":true,"event":"changed"}"""u8.ToArray();

    readonly IWritingModel writing = writingModel ?? new NoWritingModel();
    readonly HttpClient web = http ?? LinkPreview.Web;
    readonly Func<Settings> loadSettings = settings ?? Settings.Load;
    readonly Lock sending = new();  // replies (the read loop) and change events (the watcher's thread) share the output
    Stream output = Stream.Null;
    NoteStoreWatcher? watcher;

    /// Answers requests until the browser closes the pipe.
    public void Run(Stream input, Stream output)
    {
        this.output = output;
        try
        {
            while (NativeMessaging.Read(input) is { } request) Send(Handle(request));
        }
        catch (IOException) { }  // the browser hung up mid-reply
        finally
        {
            watcher?.Dispose();
        }
    }

    /// One request's reply; a request that fails gets {"ok":false,"error":…}.
    public byte[] Handle(byte[] json)
    {
        object reply;
        try { reply = Reply(JsonSerializer.Deserialize<Request>(json, Json) ?? throw new JsonException("The request was null.")); }
        catch (Exception e) { reply = Failed(e.Message); }
        return JsonSerializer.SerializeToUtf8Bytes(reply, Json);
    }

    object Reply(Request req)
    {
        switch (req.Op)
        {
            case "list":
                var settings = loadSettings();
                return new
                {
                    ok = true, notes = NoteStore.NotesUnder(req.Url ?? ""),
                    datePattern = settings.DateFormat is { Length: > 0 } pattern ? pattern : DateStyle.Region,  // the extension's editor shows dates this way
                    autoOpen = settings.OpenNotesByThemselves,
                };
            case "save":
                // The browser may only write website notes, never app notes.
                if (req.Note is not { Kind: NoteKind.Url, Target.Length: > 0 } note) return Failed("save needs a website note with a target");
                note = note with { UpdatedAt = Math.Max(note.UpdatedAt, Note.Now()) };
                NoteStore.Save(note);
                return new { ok = true, note };
            case "search":
                return new { ok = true, results = Search(req.Query ?? "").GetAwaiter().GetResult() };
            case "addImage":
                byte[] bytes;
                try { bytes = Convert.FromBase64String(req.Data ?? throw new FormatException()); }
                catch (FormatException) { return Failed("The image data was unreadable."); }
                return new { ok = true, src = NoteStore.ImageScheme + ":" + NoteStore.SaveImage(bytes, req.Mime ?? "") };
            case "image":
                if (NoteStore.Image(req.Id ?? "") is not { } image) return Failed("This image isn't on this device (yet).");
                var start = Math.Clamp(req.Offset ?? 0, 0, image.Data.Length);
                var piece = Convert.ToBase64String(image.Data, start, Math.Min(ImagePiece, image.Data.Length - start));
                return new { ok = true, data = piece, mime = image.Type, size = image.Data.Length };
            case "delete":
                NoteStore.Delete(Note.Lowercased(req.Id ?? ""));  // a panel opened before D76 may hold an uppercase id
                return new { ok = true };
            case "watch":
                // On a long-lived port (connectNative): an event whenever the app or any host process saves.
                if (watcher == null)
                {
                    watcher = new NoteStoreWatcher();
                    watcher.Changed += SendChanged;
                }
                return new { ok = true };
            case "ai":
                if (Assistant.Parse(req.Action) is not { } action) return Failed($"unknown action {req.Action}");
                return new { ok = true, text = Assistant.Run(writing, action, req.Text ?? "").GetAwaiter().GetResult() };
            case "linkPreview":
                if (!Uri.TryCreate(req.Url, UriKind.Absolute, out var url)) return Failed("That isn't a web address.");
                return new { ok = true, preview = LinkPreview.FetchAsync(url, web, toPng).GetAwaiter().GetResult() };
            default:
                return Failed($"unknown op {req.Op}");
        }
    }

    static object Failed(string error) => new { ok = false, error };

    /// By meaning and words once the app has downloaded the model; never downloading it here (~90 MB on a browser's
    /// request), so until then by words, as the app's search box.
    static async Task<List<Hit<Note>>> Search(string query)
    {
        var notes = NoteStore.LoadAll();
        var folder = Embedder.DefaultFolder;
        if (!Embedder.Files.All(file => File.Exists(Path.Combine(folder, file.Name))))
            // No similarity to rank by: each hit has every word (or the tag). As on the Mac, at most 20 (a reply stays far
            // under Chrome's 1 MB) and never a locked note.
            return [.. NoteActions.Search(notes.Where(n => !n.Locked), query).Take(20).Select(n => new Hit<Note>(n, 1))];
        using var embedder = new Embedder(folder);
        var database = new SqliteConnectionStringBuilder { DataSource = NoteStore.DatabasePath, Pooling = false }.ToString();
        return await new SearchIndex(database, embedder.EmbedAsync).SearchAsync(query, notes).ConfigureAwait(false);
    }

    void Send(byte[] message)
    {
        lock (sending) NativeMessaging.Write(output, message);
    }

    /// On the watcher's thread, where an exception would end the process.
    void SendChanged()
    {
        try { Send(ChangedEvent); }
        catch (Exception e) when (e is IOException or ObjectDisposedException) { }  // the browser hung up: Run's read ends too
    }

    sealed record Request(string? Op, string? Url, Note? Note, string? Id, string? Query, string? Action, string? Text,
        string? Mime, string? Data, int? Offset);

    sealed class NoWritingModel : IWritingModel
    {
        public string? UnavailableReason => "The writing model isn't on this PC yet: NoteAnywhere's Settings ▸ Writing model downloads it.";
        public Task<string> Respond(string instructions, string text, CancellationToken cancel) => throw new InvalidOperationException(UnavailableReason);
    }
}
