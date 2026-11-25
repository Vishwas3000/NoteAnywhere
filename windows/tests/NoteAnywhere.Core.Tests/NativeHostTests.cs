using System.IO.Pipes;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using NoteAnywhere.Core.Search;

namespace NoteAnywhere.Core.Tests;

/// The Mac's scripts/test_host.py in-process, through Handle and Run; windows/scripts/test_host.py starts the program
/// itself. These write the shared store, so the "NoteStore" collection runs them one at a time.
[Collection("NoteStore")]
public class NativeHostTests
{
    public NativeHostTests() => Assert.True(AppPaths.Data == Scratch.Dir, "would touch the real notes database");

    /// The 2×1 PNG of the Mac's LinkPreviewTests.
    static readonly byte[] Png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAEUlEQVR42mP4z8DwHwyB+AMAYMQK9v1ByAoAAAAASUVORK5CYII=");
    static readonly byte[] Ico = [0, 0, 1, 0, 2, 0, 16, 16], Bmp = [.. "BM"u8, 1, 2, 3];

    // Default settings, not settings.json, which SettingsTests rewrites meanwhile.
    static NativeHost Host(IWritingModel? model = null, Func<byte[], byte[]>? toPng = null, HttpClient? http = null) =>
        new(model, toPng, http, () => new Settings());

    static JsonNode Call(object request, NativeHost? host = null) =>
        JsonNode.Parse((host ?? Host()).Handle(JsonSerializer.SerializeToUtf8Bytes(request)))!;

    static bool Ok(JsonNode reply) => (bool)reply["ok"]!;
    static string Error(object request, NativeHost? host = null) => (string)Call(request, host)["error"]!;
    static string NewID() => Guid.NewGuid().ToString();
    static string NewSite() => Guid.NewGuid().ToString("N") + ".com";

    static object WebsiteNote(string id, string target, double at = 1, string kind = "url") =>
        new { id, kind, target, label = target, text = "hi " + target, createdAt = at, updatedAt = at };

    static string[] Ids(JsonNode reply, string list = "notes") =>
        [.. reply[list]!.AsArray().Select(n => (string)(list == "notes" ? n!["id"] : n!["note"]!["id"])!)];

    static (byte[] Data, string Type) Kept(string src)
    {
        Assert.StartsWith("noteimage:", src);
        return NoteStore.Image(src["noteimage:".Length..]) ?? throw new InvalidOperationException($"{src} isn't kept");
    }

    [Fact]
    public void ListShowsAPageAndThePagesUnderIt()
    {
        var site = NewSite();
        string home = NewID(), page = NewID();
        Assert.True(Ok(Call(new { op = "save", note = WebsiteNote(home, site, 1) })));
        Assert.True(Ok(Call(new { op = "save", note = WebsiteNote(page, site + "/vercel/next.js", 2) })));
        string[] Under(string url) => Ids(Call(new { op = "list", url }));
        Assert.Equal([home, page], Under(site + "/"));
        Assert.Equal([page], Under(site + "/vercel"));
        Assert.Equal([page], Under(site + "/vercel/next.js/"));
        Assert.Empty(Under(site + "/vercel/next.jsx"));
        Assert.Empty(Under(site.Replace(".com", ".company.com") + "/"));

        // Settings ▸ General: how the extension's editor shows dates, and whether a page's notes open by themselves.
        var region = Call(new { op = "list", url = site });
        Assert.Equal((DateStyle.Region, true), ((string)region["datePattern"]!, (bool)region["autoOpen"]!));
        var chosen = Call(new { op = "list", url = site },
            new NativeHost(settings: () => new Settings { DateFormat = "d MMM yyyy", OpenNotesByThemselves = false }));
        Assert.Equal(("d MMM yyyy", false), ((string)chosen["datePattern"]!, (bool)chosen["autoOpen"]!));
    }

    [Fact]
    public void TheBrowserSavesOnlyWebsiteNotesWithATarget()
    {
        var id = NewID();
        Assert.Equal("save needs a website note with a target", Error(new { op = "save", note = WebsiteNote(id, "x.com", kind: "app") }));
        Assert.Equal("save needs a website note with a target", Error(new { op = "save", note = WebsiteNote(id, "") }));
        Assert.Equal("save needs a website note with a target", Error(new { op = "save" }));
        Assert.Equal("Not a note id.", Error(new { op = "save", note = WebsiteNote("../../evil", "x.com") }));
        Assert.DoesNotContain(NoteStore.LoadAll(), n => n.Id == id);

        // A tab's clock may be behind: what's saved is never older than now.
        var now = Note.Now();
        var saved = Call(new { op = "save", note = WebsiteNote(id, NewSite(), 5) })["note"]!;
        Assert.Equal(5, (double)saved["createdAt"]!);
        Assert.InRange((double)saved["updatedAt"]!, now, now + 60_000);
        Assert.Equal((double)saved["updatedAt"]!, NoteStore.LoadAll().Single(n => n.Id == id).UpdatedAt);
    }

    [Fact]
    public void UppercaseIdsAreLowercasedAndADeleteSticks()
    {
        string site = NewSite(), id = NewID();
        Assert.Equal(id, (string)Call(new { op = "save", note = WebsiteNote(id.ToUpperInvariant(), site) })["note"]!["id"]!);
        Assert.Equal([id], Ids(Call(new { op = "list", url = site })));
        Assert.True(Ok(Call(new { op = "delete", id = id.ToUpperInvariant() })));  // a panel opened before D76 holds capitals
        Assert.Empty(Ids(Call(new { op = "list", url = site })));
        // A late save from a tab that still shows it can't bring it back.
        Assert.True(Ok(Call(new { op = "save", note = WebsiteNote(id, site, 3) })));
        Assert.Empty(Ids(Call(new { op = "list", url = site })));
        Assert.Equal("Not a note id.", Error(new { op = "delete" }));
    }

    [Fact]
    public void ImagesAreKeptAndReadBackInPieces()
    {
        var big = new byte[1_300_000];
        new Random(86).NextBytes(big);
        var src = (string)Call(new { op = "addImage", mime = "image/png", data = Convert.ToBase64String(big) })["src"]!;
        var id = src["noteimage:".Length..];
        Assert.Equal((big, "image/png"), Kept(src), new BytesAndType());

        List<byte[]> pieces = [];
        for (var got = 0; got < big.Length; got += pieces[^1].Length)
        {
            var raw = Host().Handle(JsonSerializer.SerializeToUtf8Bytes(new { op = "image", id, offset = got }));
            Assert.True(raw.Length < 1 << 20, "Chrome refuses a reply over 1 MB");
            var reply = JsonNode.Parse(raw)!;
            Assert.Equal(("image/png", big.Length), ((string)reply["mime"]!, (int)reply["size"]!));
            pieces.Add(Convert.FromBase64String((string)reply["data"]!));
        }
        Assert.Equal([600_000, 600_000, 100_000], pieces.Select(p => p.Length));
        Assert.Equal(big, pieces.SelectMany(p => p));
        Assert.Equal("", (string)Call(new { op = "image", id, offset = 2_000_000 })["data"]!);
        Assert.Equal(600_000, Convert.FromBase64String((string)Call(new { op = "image", id, offset = -5 })["data"]!).Length);

        Assert.Contains("can't hold", Error(new { op = "addImage", mime = "image/svg+xml", data = "PHN2Zz4=" }));
        Assert.Equal("The image data was unreadable.", Error(new { op = "addImage", mime = "image/png", data = "not base64!" }));
        Assert.Equal("The image data was unreadable.", Error(new { op = "addImage", mime = "image/png" }));
        Assert.Equal("Images can be up to 20 MB.", Error(new { op = "addImage", mime = "image/png", data = Convert.ToBase64String(new byte[(20 << 20) + 1]) }));
        Assert.Equal("This image isn't on this device (yet).", Error(new { op = "image", id = "../memorynotes.sqlite" }));
        Assert.Equal("This image isn't on this device (yet).", Error(new { op = "image", id = NewID() }));
    }

    sealed class BytesAndType : IEqualityComparer<(byte[] Data, string Type)>
    {
        public bool Equals((byte[] Data, string Type) a, (byte[] Data, string Type) b) => a.Data.SequenceEqual(b.Data) && a.Type == b.Type;
        public int GetHashCode((byte[] Data, string Type) value) => value.Type.GetHashCode();
    }

    [Fact]
    public void SearchByWordsNeverStartsTheModelDownload()
    {
        var word = "zq" + Guid.NewGuid().ToString("N")[..10];
        string site = NewSite(), older = NewID(), newer = NewID(), sealedNote = NewID();
        Call(new { op = "save", note = new { id = older, kind = "url", target = site, label = "", text = $"Routing in {word} apps #{word}x", createdAt = 1, updatedAt = 1 } });
        Call(new { op = "save", note = new { id = newer, kind = "url", target = site, label = "", text = $"More {word} notes", createdAt = 2, updatedAt = 2 } });
        NoteStore.Save(new Note { Id = sealedNote, Kind = NoteKind.Url, Target = site, Label = "", Text = word });
        NoteStore.SetLocked(sealedNote, "mnlock:v1:sealed", locked: true);

        var hits = Call(new { op = "search", query = word });
        Assert.Equal([newer, older], Ids(hits, "results"));  // every word, newest first
        Assert.All(hits["results"]!.AsArray(), hit => Assert.Equal(1, (double)hit!["score"]!));
        Assert.Equal([older], Ids(Call(new { op = "search", query = $"#{word}x" }), "results"));
        // A locked note's title is "Locked Note", and its text would show as its sealed envelope: the browser never gets one.
        Assert.All(Call(new { op = "search", query = "Locked Note" })["results"]!.AsArray(), hit => Assert.False((bool)hit!["note"]!["locked"]!));
        Assert.Empty(Ids(Call(new { op = "search", query = " " }), "results"));
        Assert.False(Directory.Exists(Path.Combine(AppPaths.Data, "models")), "a browser's search started the model download");
    }

    /// With the app's copy of the model (EmbedderTests' download, put where the app keeps it), search goes by meaning.
    [Search.ModelFact]
    public async Task SearchByMeaningOnceTheAppHasTheModel()
    {
        var download = Path.Combine(Path.GetTempPath(), "noteanywhere-model");
        using (var embedder = new Embedder(download)) Assert.NotNull(await embedder.EmbedAsync("download it, if it isn't here yet"));
        Directory.CreateDirectory(Embedder.DefaultFolder);
        try
        {
            foreach (var (name, _, _) in Embedder.Files) File.Copy(Path.Combine(download, name), Path.Combine(Embedder.DefaultFolder, name));
            string site = NewSite(), pasta = NewID();
            Call(new { op = "save", note = new { id = NewID(), kind = "url", target = site, label = "", text = "Walked the dog in the park this morning; she chased a squirrel.", createdAt = 1, updatedAt = 1 } });
            Call(new { op = "save", note = new { id = pasta, kind = "url", target = site, label = "", text = "Pasta: garlic, olive oil and chili flakes.", createdAt = 1, updatedAt = 1 } });
            var hits = Call(new { op = "search", query = "dinner ideas" });  // no word in common with any note
            Assert.Equal(pasta, Ids(hits, "results")[0]);
            Assert.InRange((double)hits["results"]![0]!["score"]!, 0.3, 0.5);
        }
        finally
        {
            Directory.Delete(Path.Combine(AppPaths.Data, "models"), recursive: true);
        }
    }

    sealed class Model(string? unavailable = null) : IWritingModel
    {
        public string? UnavailableReason => unavailable;
        public Task<string> Respond(string instructions, string text, CancellationToken cancel) => Task.FromResult($"```\n{text.ToUpperInvariant()}\n```");
    }

    [Fact]
    public void AiRunsOnTheWritingModelItIsGiven()
    {
        var host = Host(new Model());
        Assert.Equal("TEH MEETING", (string)Call(new { op = "ai", action = "proofread", text = "teh meeting" }, host)["text"]!);
        Assert.Equal("unknown action nope", Error(new { op = "ai", action = "nope", text = "x" }, host));
        Assert.Equal("Write something first.", Error(new { op = "ai", action = "shorten", text = " " }, host));
        Assert.Equal("Not yet", Error(new { op = "ai", action = "title", text = "x" }, Host(new Model("Not yet"))));
        Assert.Equal("The writing model isn't on this PC yet: open NoteAnywhere and choose ✨ to download it.",
            Error(new { op = "ai", action = "proofread", text = "teh meeting" }));
    }

    /// The web as a table of addresses; `moved` is where a redirect ends, as SocketsHttpHandler reports it: the response's request.
    sealed class Web(Dictionary<string, byte[]> pages, Dictionary<string, string>? moved = null) : HttpMessageHandler
    {
        public List<string> Asked { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancel)
        {
            lock (Asked) Asked.Add(request.RequestUri!.AbsoluteUri);
            if (moved?.GetValueOrDefault(request.RequestUri.AbsoluteUri) is { } to) request.RequestUri = new Uri(to);
            return Task.FromResult(pages.TryGetValue(request.RequestUri.AbsoluteUri, out var body)
                ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(body), RequestMessage = request }
                : new HttpResponseMessage(HttpStatusCode.NotFound) { RequestMessage = request });
        }
    }

    [Fact]
    public void LinkPreviewFetchesThePageAndKeepsItsPictures()
    {
        var html = """
            <html><head><title>Not this</title>
            <meta property="og:title" content="A post &amp; its pictures">
            <meta name="description" content="What the post says.">
            <link rel="icon" href="icon.ico">
            <meta property="og:image" content="https://cdn.example.com/cover.png">
            </head><body></body></html>
            """;
        var web = new Web(new()
        {
            ["https://example.com/blog/post"] = Encoding.UTF8.GetBytes(html),
            ["https://example.com/blog/icon.ico"] = Ico,  // relative to where the redirect ended, not to /p/1
            ["https://cdn.example.com/cover.png"] = Png,
        }, new() { ["https://example.com/p/1"] = "https://example.com/blog/post" });
        List<byte[]> converted = [];
        byte[] ToPng(byte[] picture)
        {
            lock (converted) converted.Add(picture);
            return [.. Png, .. "converted"u8];
        }
        var preview = Call(new { op = "linkPreview", url = "https://example.com/p/1" }, Host(toPng: ToPng, http: new HttpClient(web)))["preview"]!;

        Assert.Equal(("A post & its pictures", "What the post says."), ((string)preview["title"]!, (string)preview["description"]!));
        Assert.Equal(([.. Png, .. "converted"u8], "image/png"), Kept((string)preview["icon"]!), new BytesAndType());
        Assert.Equal((Png, "image/png"), Kept((string)preview["image"]!), new BytesAndType());  // a type notes hold: kept as it came
        Assert.Equal([Ico], converted);
    }

    [Fact]
    public void LinkPreviewReadsTheFirst2MBAndSaysWhatWentWrong()
    {
        // Only the first 2 MB count, so the og:title after them doesn't; cut through the "é" there, the page is still
        // UTF-8, not Latin-1's "CafÃ©".
        var page = Encoding.UTF8.GetBytes("<title>Café</title>" + new string(' ', (2 << 20) - 21) + "é<meta property=\"og:title\" content=\"Too late\">");
        var web = new Web(new() { ["https://example.com/"] = page });
        var preview = Call(new { op = "linkPreview", url = "https://example.com/" }, Host(http: new HttpClient(web)))["preview"]!;
        Assert.Equal(("Café", "", ""), ((string)preview["title"]!, (string)preview["icon"]!, (string)preview["image"]!));
        Assert.Contains("https://example.com/favicon.ico", web.Asked);  // the site's icon stands in, and isn't there

        var host = Host(http: new HttpClient(web));
        Assert.Equal("example.com answered 404.", Error(new { op = "linkPreview", url = "https://example.com/gone" }, host));
        Assert.Equal("Only web addresses (http or https) have previews.", Error(new { op = "linkPreview", url = "ftp://example.com/" }, host));
        Assert.Equal("That isn't a web address.", Error(new { op = "linkPreview", url = "example dot com" }, host));
        Assert.Equal("That isn't a web address.", Error(new { op = "linkPreview" }, host));
    }

    /// The Mac's picturesBecomeTypesNotesHold and savesPictureAsNoteImage; the app's toPng (WPF) is tested on Windows by test_host.py.
    [Fact]
    public async Task PicturesAreKeptAsTypesNotesHold()
    {
        static byte[] ToPng(byte[] picture) => Png;
        Assert.Same(Png, LinkPreview.Picture(Png, ToPng).Data);
        Assert.Equal("image/png", LinkPreview.Picture(Png, ToPng).Type);
        Assert.Equal("image/jpeg", LinkPreview.Picture([0xFF, 0xD8, 0xFF, 0xE0], ToPng).Type);
        Assert.Equal("image/gif", LinkPreview.Picture("GIF89a"u8.ToArray(), ToPng).Type);
        Assert.Equal("image/webp", LinkPreview.Picture([.. "RIFF"u8, 0, 0, 0, 0, .. "WEBPVP8 "u8], ToPng).Type);
        Assert.Equal("image/avif", LinkPreview.Picture([0, 0, 0, 28, .. "ftypavif"u8, 0, 0, 0, 0], ToPng).Type);
        Assert.Equal("image/heic", LinkPreview.Picture([0, 0, 0, 24, .. "ftypheic"u8, 0, 0, 0, 0], ToPng).Type);
        Assert.Equal((Png, "image/png"), LinkPreview.Picture(Ico, ToPng));  // a favicon.ico: what toPng made of it
        Assert.Equal((Png, "image/png"), LinkPreview.Picture(Bmp, ToPng));
        Assert.Throws<InvalidOperationException>(() => LinkPreview.Picture(Ico, null));
        Assert.Throws<InvalidOperationException>(() => LinkPreview.Picture("""<svg xmlns="http://www.w3.org/2000/svg"/>"""u8.ToArray(), ToPng));
        Assert.Throws<InvalidOperationException>(() => LinkPreview.Picture("<html>Not found</html>"u8.ToArray(), ToPng));

        var web = new Web(new() { ["https://example.com/huge.png"] = [.. Png, .. new byte[5 << 20]] });
        var http = new HttpClient(web);
        var src = await LinkPreview.SavePictureAsync("data:image/png;base64," + Convert.ToBase64String(Png), http, null);
        Assert.Equal((Png, "image/png"), Kept(src), new BytesAndType());
        Assert.Equal("", await LinkPreview.SavePictureAsync("", http, null));
        Assert.Equal("", await LinkPreview.SavePictureAsync("file:///etc/hosts", http, null));  // a page can't pull in local files
        Assert.Equal("", await LinkPreview.SavePictureAsync("https://example.com/huge.png", http, null));  // over 5 MB
        Assert.Equal("", await LinkPreview.SavePictureAsync("https://example.com/missing.png", http, null));
        Assert.Equal(["https://example.com/huge.png", "https://example.com/missing.png"], web.Asked);
    }

    [Fact]
    public async Task AWatchingConnectionHearsOfAnotherConnectionsSave()
    {
        var toHost = new AnonymousPipeServerStream(PipeDirection.Out);
        var fromHost = new AnonymousPipeServerStream(PipeDirection.In);
        var hostInput = new AnonymousPipeClientStream(PipeDirection.In, toHost.ClientSafePipeHandle);
        var hostOutput = new AnonymousPipeClientStream(PipeDirection.Out, fromHost.ClientSafePipeHandle);
        try
        {
            var running = Task.Run(() => Host().Run(hostInput, hostOutput));
            NativeMessaging.Write(toHost, """{"op":"watch"}"""u8);
            Assert.Equal("""{"ok":true}""", Encoding.UTF8.GetString(NativeMessaging.Read(fromHost)!));
            var heard = Task.Run(() => NativeMessaging.Read(fromHost));
            Assert.NotSame(heard, await Task.WhenAny(heard, Task.Delay(TimeSpan.FromSeconds(1))));  // nothing until a change
            Assert.True(Ok(Call(new { op = "save", note = WebsiteNote(NewID(), NewSite()) })));  // as another tab's host would
            Assert.Same(heard, await Task.WhenAny(heard, Task.Delay(TimeSpan.FromSeconds(10))));
            Assert.Equal("""{"ok":true,"event":"changed"}""", Encoding.UTF8.GetString((await heard)!));

            toHost.Dispose();  // the browser closes the pipe, and Run ends
            Assert.Same(running, await Task.WhenAny(running, Task.Delay(TimeSpan.FromSeconds(10))));
        }
        finally
        {
            // Writers first, even after a failure: disposing a pipe waits for a read blocked on it (.NET 10 on the Mac), and
            // only a closed writer ends that read.
            foreach (var pipe in (Stream[])[toHost, hostOutput, hostInput, fromHost]) pipe.Dispose();
        }
    }

    [Fact]
    public void RunAnswersInTurnAndUnknownOpsGetAnError()
    {
        var input = new MemoryStream();
        NativeMessaging.Write(input, """{"op":"nope"}"""u8);
        NativeMessaging.Write(input, "not json"u8);
        NativeMessaging.Write(input, """{"op":"save","note":{"id":"a","kind":"folder","target":"x.com","label":"","createdAt":1,"updatedAt":1}}"""u8);
        NativeMessaging.Write(input, """{"op":"delete","id":"00000000-0000-0000-0000-000000000000"}"""u8);
        input.Position = 0;
        var output = new MemoryStream();
        Host().Run(input, output);  // returns once the input ends, as when the browser closes the pipe

        output.Position = 0;
        string Next() => Encoding.UTF8.GetString(NativeMessaging.Read(output)!);
        Assert.Equal("""{"ok":false,"error":"unknown op nope"}""", Next());
        Assert.StartsWith("""{"ok":false,"error":""", Next());
        Assert.Equal("""{"ok":false,"error":"A note's kind is \"app\" or \"url\"."}""", Next());
        Assert.Equal("""{"ok":true}""", Next());
        Assert.Null(NativeMessaging.Read(output));
    }
}
