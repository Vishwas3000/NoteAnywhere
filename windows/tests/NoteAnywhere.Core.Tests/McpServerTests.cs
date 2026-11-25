using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using NoteAnywhere.Core.Search;
using NoteAnywhere.Core.Tests.Search;

namespace NoteAnywhere.Core.Tests;

/// The MCP server as AI apps drive it, a JSON-RPC line at a time: scripts/test_mcp.py and MCPServerTests.swift, on the
/// scratch store. Other tests' notes share that store, so each test looks only at the notes it made.
[Collection("NoteStore")]
public class McpServerTests
{
    public McpServerTests() => Assert.True(AppPaths.Data == Scratch.Dir, "would touch the real notes database");

    const string Modern = """{"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}}""";
    static int sequence;

    static JsonElement Send(string method, string parameters = "{}")
    {
        var id = ++sequence;
        var reply = McpServer.Handle($$"""{"jsonrpc": "2.0", "id": {{id}}, "method": "{{method}}", "params": {{parameters}}}""");
        var message = JsonDocument.Parse(reply ?? "null").RootElement;
        Assert.Equal(id, message.GetProperty("id").GetInt32());
        return message;
    }

    static JsonElement Result(string method, string parameters = "{}") => Send(method, parameters).GetProperty("result");

    static (int Code, string Message) Failure(string method, string parameters = "{}")
    {
        var error = Send(method, parameters).GetProperty("error");
        return (error.GetProperty("code").GetInt32(), Str(error, "message"));
    }

    /// A tool's reply: JSON, or a sentence for the model when it failed. Arguments are an object, or JSON as written.
    static (string Text, bool Failed) Call(string tool, object? arguments = null)
    {
        var json = arguments as string ?? JsonSerializer.Serialize(arguments ?? new { });
        var result = Result("tools/call", $$"""{"name": "{{tool}}", "arguments": {{json}}}""");
        return (Str(result.GetProperty("content")[0], "text"), result.GetProperty("isError").GetBoolean());
    }

    static JsonElement Ok(string tool, object? arguments = null)
    {
        var (text, failed) = Call(tool, arguments);
        Assert.False(failed, $"{tool}: {text}");
        return JsonDocument.Parse(text).RootElement;
    }

    static string Refused(string tool, object? arguments = null)
    {
        var (text, failed) = Call(tool, arguments);
        Assert.True(failed, $"{tool} should have been refused: {text}");
        return text;
    }

    static string Create(object arguments) => Str(Ok("create_note", arguments), "id");
    static string Str(JsonElement o, string key) => o.GetProperty(key).GetString()!;
    static List<string> Ids(JsonElement list) => [.. list.EnumerateArray().Select(item => Str(item, "id"))];
    static string Updated(string id) => McpServer.Iso(NoteStore.LoadAll().Single(note => note.Id == id).UpdatedAt);
    static string Unique() => "u" + Guid.NewGuid().ToString("N")[..10];

    /// A file of this repo, found from where the tests run (windows/tests/…/bin/…).
    static string Repo(string path)
    {
        for (var folder = new DirectoryInfo(AppContext.BaseDirectory); folder != null; folder = folder.Parent)
            if (File.Exists(Path.Combine(folder.FullName, path))) return Path.Combine(folder.FullName, path);
        throw new FileNotFoundException($"No {path} above {AppContext.BaseDirectory}");
    }

    [Fact]
    public void TheLegacyHandshake()
    {
        var init = Result("initialize", """{"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}""");
        Assert.Equal("2025-06-18", Str(init, "protocolVersion"));
        Assert.Equal("""{"tools":{}}""", init.GetProperty("capabilities").GetRawText());
        Assert.Equal($$"""{"name":"NoteAnywhere","version":"{{File.ReadAllText(Repo("VERSION")).Trim()}}"}""", init.GetProperty("serverInfo").GetRawText());
        Assert.False(init.TryGetProperty("resultType", out _));  // only the modern era's results carry it
        Assert.Equal("2025-11-25", Str(Result("initialize", """{"protocolVersion": "2099-01-01"}"""), "protocolVersion"));
        Assert.Null(McpServer.Handle("""{"jsonrpc": "2.0", "method": "notifications/initialized"}"""));
        Assert.Equal("{}", Result("ping").GetRawText());
    }

    [Fact]
    public void TheModernEra()
    {
        var discover = Result("server/discover", Modern);
        Assert.Equal("""["2026-07-28"]""", discover.GetProperty("supportedVersions").GetRawText());
        Assert.Equal("complete", Str(discover, "resultType"));
        Assert.Equal("NoteAnywhere", Str(discover.GetProperty("_meta").GetProperty("io.modelcontextprotocol/serverInfo"), "name"));
        var bad = Send("tools/list", """{"_meta": {"io.modelcontextprotocol/protocolVersion": "1900-01-01", "io.modelcontextprotocol/clientCapabilities": {}}}""");
        Assert.Equal("""{"code":-32022,"data":{"requested":"1900-01-01","supported":["2026-07-28","2025-11-25","2025-06-18","2025-03-26","2024-11-05"]},"message":"Unsupported protocol version"}""",
            bad.GetProperty("error").GetRawText());
        Assert.Equal((-32602, "Missing _meta.io.modelcontextprotocol/clientCapabilities"),
            Failure("tools/list", """{"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}}"""));
        Assert.Equal((-32602, "Missing _meta.io.modelcontextprotocol/protocolVersion"), Failure("server/discover"));
        Assert.Equal("complete", Str(Result("tools/list", Modern), "resultType"));
        var call = Result("tools/call", """{"name": "list_folders", "_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}}""");
        Assert.Equal(("complete", false), (Str(call, "resultType"), call.GetProperty("isError").GetBoolean()));
    }

    /// The protocol versions, the instructions and every tool's name, description and schema are the Mac's word for word,
    /// read from MCPServer.swift itself so the two can't drift apart.
    [Fact]
    public void TheMacsWordsWordForWord()
    {
        var swift = File.ReadAllText(Repo("Sources/MemoryNotes/MCPServer.swift")).Replace("\r\n", "\n");  // a Windows checkout may have CRLF
        static string Unescape(string literal) => literal.Replace("\\\"", "\"");
        static string[] Literals(string list) => [.. Regex.Matches(list, "\"([^\"]*)\"").Select(m => m.Groups[1].Value)];

        var modern = Literals(Regex.Match(swift, @"static let modern = \[(.*?)\]").Groups[1].Value);
        var legacy = Literals(Regex.Match(swift, @"static let legacy = \[(.*?)\]").Groups[1].Value);
        Assert.Equal(modern, Result("server/discover", Modern).GetProperty("supportedVersions").EnumerateArray().Select(v => v.GetString()));
        var refused = Send("ping", """{"_meta": {"io.modelcontextprotocol/protocolVersion": "0", "io.modelcontextprotocol/clientCapabilities": {}}}""");
        Assert.Equal([.. modern, .. legacy], refused.GetProperty("error").GetProperty("data").GetProperty("supported").EnumerateArray().Select(v => v.GetString()));
        Assert.Equal(legacy[0], Str(Result("initialize"), "protocolVersion"));

        var instructions = string.Concat(Regex.Match(swift, "static let instructions = \"\"\"\n(.*?)\n\\s*\"\"\"", RegexOptions.Singleline).Groups[1].Value
            .Split('\n').Select(line => line.Trim().TrimEnd('\\')));
        Assert.Contains("a Mac notes app", instructions);
        Assert.Equal(instructions.Replace("a Mac notes app", "a Windows notes app"), Str(Result("initialize"), "instructions"));

        var tools = Result("tools/list").GetProperty("tools").EnumerateArray().ToList();
        var specs = Regex.Matches(swift, @"Tool\(name: ""(\w+)"",\s*description: ""((?:[^""\\]|\\.)*)""(.*?)\) \{ \w+ in", RegexOptions.Singleline);
        Assert.Equal(11, specs.Count);
        Assert.Equal(specs.Select(spec => spec.Groups[1].Value), tools.Select(tool => Str(tool, "name")));
        foreach (var (spec, tool) in specs.Zip(tools))
        {
            var rest = spec.Groups[3].Value;
            Assert.Equal(Unescape(spec.Groups[2].Value), Str(tool, "description"));
            // "query": text("…") or number("…"), or ["type": "boolean", "description": "…"], the colour's with an "enum"
            var properties = Regex.Matches(rest, @"""(\w+)"": (?:(text|number)\(|\[""type"": ""(\w+)"",(?: ""enum"": [^,]*,)? ""description"": )""((?:[^""\\]|\\.)*)""")
                .Select(p => (p.Groups[1].Value, p.Groups[2].Value switch { "text" => "string", "number" => "integer", _ => p.Groups[3].Value }, Unescape(p.Groups[4].Value)))
                .OrderBy(p => p.Item1, StringComparer.Ordinal);
            var schema = tool.GetProperty("inputSchema");
            Assert.Equal("object", Str(schema, "type"));
            Assert.Equal(properties, schema.GetProperty("properties").EnumerateObject().Select(p => (p.Name, Str(p.Value, "type"), Str(p.Value, "description"))));
            var required = Regex.Match(rest, @"required: \[([^\]]*)\]");
            Assert.Equal(required.Success ? Literals(required.Groups[1].Value) : [],
                schema.TryGetProperty("required", out var names) ? names.EnumerateArray().Select(name => name.GetString()!) : []);
            Assert.Equal(rest.Contains("readOnly: true") ? """{"readOnlyHint":true}"""
                : $$"""{"destructiveHint":{{(rest.Contains("destructive: true") ? "true" : "false")}},"openWorldHint":false,"readOnlyHint":false}""",
                tool.GetProperty("annotations").GetRawText());
        }
        var colors = Regex.Match(File.ReadAllText(Repo("Sources/MemoryNotes/Note.swift")), @"enum NoteColor\b[^{]*\{\s*case ([^\r\n]*)").Groups[1].Value.Split(", ");
        var color = tools.Single(tool => Str(tool, "name") == "update_note").GetProperty("inputSchema").GetProperty("properties").GetProperty("color");
        Assert.Equal([.. colors, "none"], color.GetProperty("enum").EnumerateArray().Select(c => c.GetString()));
        Assert.DoesNotContain(tools, tool => Str(tool, "name").Contains("delete"));
    }

    [Fact]
    public void ProtocolErrors()
    {
        Assert.Equal((-32602, "Unknown tool: delete_note"), Failure("tools/call", """{"name": "delete_note", "arguments": {}}"""));
        Assert.Equal((-32601, "Method not found: nope"), Failure("nope"));
        const string parseError = """{"error":{"code":-32700,"message":"Parse error"},"id":null,"jsonrpc":"2.0"}""";
        Assert.Equal(parseError, McpServer.Handle("{not json"));
        Assert.Equal(parseError, McpServer.Handle("[1, 2]"));
        Assert.Equal(parseError, McpServer.Handle("""{"jsonrpc": "2.0", "id": 1, "method": "\ud83d"}"""));  // half an emoji
        Assert.True(Call("get_note", """{"id": "\ud83d"}""").Failed);  // in a tool's arguments too, and the server goes on
        Assert.Equal("""{"error":{"code":-32600,"message":"Invalid request"},"id":null,"jsonrpc":"2.0"}""", McpServer.Handle("""{"jsonrpc": "2.0"}"""));
        Assert.Null(McpServer.Handle("""{"jsonrpc": "2.0", "id": 7, "result": {}}"""));  // a response: the server sends no requests
        Assert.Null(McpServer.Handle("""{"jsonrpc": "2.0", "id": null, "method": "ping"}"""));
        Assert.Equal("""{"id":"a/b","jsonrpc":"2.0","result":{}}""", McpServer.Handle("""{"jsonrpc": "2.0", "id": "a/b", "method": "ping"}"""));
    }

    [Fact]
    public void RunAnswersEachLineOnALineOfItsOwn()
    {
        var output = new StringWriter();
        McpServer.Run(new StringReader("""
            {"jsonrpc": "2.0", "id": 1, "method": "ping"}

            {"jsonrpc": "2.0", "method": "notifications/initialized"}
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}
            """.Replace("\n", "\r\n")), output);  // as a Windows client may end its lines
        var lines = output.ToString().Split('\n');
        Assert.Equal(3, lines.Length);  // two replies, each ending in "\n" alone, then nothing
        Assert.Equal("""{"id":1,"jsonrpc":"2.0","result":{}}""", lines[0]);
        Assert.StartsWith("""{"id":2,"jsonrpc":"2.0","result":{"tools":[{"annotations":{"readOnlyHint":true},"description":"Find notes""", lines[1]);
        Assert.Contains("""(\"- [ ] …\")""", lines[1]);  // beyond ASCII as it is, not \u2026
        Assert.Equal("", lines[2]);
    }

    [Fact]
    public void CreateAppendAndRead()
    {
        var plan = Create(new { text = "Launch plan\n- [ ] Call the printer @2026-10-30 #launch" });
        var appended = Ok("append_to_note", new { id = plan, text = "- [ ] Book the venue @2026-11-02" });
        Assert.Equal(["id", "title", "updated_at"], appended.EnumerateObject().Select(p => p.Name));
        var note = Ok("get_note", new { id = plan });
        Assert.Equal(["created", "dates", "id", "kind", "tags", "text", "title", "updated", "updated_at"], note.EnumerateObject().Select(p => p.Name));
        Assert.Equal("Launch plan\n- [ ] Call the printer @2026-10-30 #launch\n- [ ] Book the venue @2026-11-02", Str(note, "text"));
        Assert.Equal(("Launch plan", "plain", """["launch"]"""), (Str(note, "title"), Str(note, "kind"), note.GetProperty("tags").GetRawText()));
        Assert.Equal("""[{"day":"2026-10-30","done":false,"line":1,"task":true,"text":"Call the printer #launch"},{"day":"2026-11-02","done":false,"line":2,"task":true,"text":"Book the venue"}]""",
            note.GetProperty("dates").GetRawText());
        Assert.Equal(appended.GetProperty("updated_at").GetInt64(), note.GetProperty("updated_at").GetInt64());
        Assert.Equal(Updated(plan), Str(note, "updated"));

        var page = Create(new { text = "Read the caching docs", url = "https://www.github.com/vercel/next.js/?tab=readme#top" });
        var web = Ok("get_note", new { id = page });
        Assert.Equal(("website", "github.com/vercel/next.js", "github.com", "github.com"), (Str(web, "kind"), Str(web, "target"), Str(web, "source"), Str(web, "label")));
        Assert.Equal("example.com/launch", Str(Ok("get_note", new { id = Create(new { text = "x", url = "example.com/launch" }) }), "target"));  // https:// assumed

        var count = NoteStore.LoadAll().Count;
        Assert.Equal("url must be a web address, like https://github.com/apple/swift", Refused("create_note", new { text = "x", url = "ftp://nope" }));
        Assert.StartsWith("No folder \"Nowhere\". Folders: ", Refused("create_note", new { text = "x", folder = "Nowhere" }));
        Assert.Equal("text is required (a string)", Refused("create_note", new { text = 5 }));
        Assert.Equal(count, NoteStore.LoadAll().Count);  // none of them made a note
        Assert.Equal("No note with id aaaaaaaa-0000-0000-0000-000000000000. Find ids with search_notes or list_notes.",
            Refused("get_note", new { id = "aaaaaaaa-0000-0000-0000-000000000000" }));
        Assert.Equal("id is required (a string)", Refused("get_note"));
        Assert.Equal(plan, Str(Ok("get_note", new { id = plan.ToUpperInvariant() }), "id"));  // ids given out before D76 were uppercase
    }

    [Fact]
    public void TasksByDay()
    {
        var plan = Create(new { text = "Launch plan\n- [ ] Call the printer @2071-10-30\n- [ ] Book the venue @2071-11-02\nDentist @2071-11-05{red} #demo" });
        var october = Ok("list_tasks", new { @from = "2071-10-01", to = "2071-10-31" });
        Assert.Equal($$"""{"lines":[{"day":"2071-10-30","done":false,"line":1,"note_id":"{{plan}}","note_title":"Launch plan","task":true,"text":"Call the printer"}],"total":1}""",
            october.GetRawText());
        var ticked = Ok("set_task_done", new { id = plan, line = 1, done = true });
        Assert.Equal("Launch plan\n- [x] Call the printer @2071-10-30\n- [ ] Book the venue @2071-11-02\nDentist @2071-11-05{red} #demo", Str(Ok("get_note", new { id = plan }), "text"));
        static List<string> Days(JsonElement tasks) => [.. tasks.GetProperty("lines").EnumerateArray().Select(line => Str(line, "day"))];
        Assert.Equal(["2071-11-02", "2071-11-05"], Days(Ok("list_tasks", new { @from = "2071-01-01", to = "2071-12-31" })));  // the ticked one drops out
        var all = Ok("list_tasks", new { @from = "2071-01-01", to = "2071-12-31", include_done = true });
        Assert.Equal(["2071-10-30", "2071-11-02", "2071-11-05"], Days(all));
        // Not a task, and its colour isn't in its words.
        Assert.Equal($$"""{"day":"2071-11-05","line":3,"note_id":"{{plan}}","note_title":"Launch plan","text":"Dentist #demo"}""", all.GetProperty("lines")[2].GetRawText());
        var first = Ok("list_tasks", new { @from = "2071-01-01", to = "2071-12-31", include_done = true, limit = 1 });
        Assert.Equal((3, 1), (first.GetProperty("total").GetInt32(), first.GetProperty("lines").GetArrayLength()));
        // Ticking a ticked item changes nothing and says so, without a title, as on the Mac; a line may come as 1.0.
        Assert.Equal($$"""{"id":"{{plan}}","updated_at":{{ticked.GetProperty("updated_at").GetInt64()}}}""",
            Ok("set_task_done", $$"""{"id": "{{plan}}", "line": 1.0, "done": true}""").GetRawText());
        Assert.Equal("Line 0 isn't a checklist item (\"- [ ] …\")", Refused("set_task_done", new { id = plan, line = 0, done = true }));
        Assert.Equal("Line 9 isn't a checklist item (\"- [ ] …\")", Refused("set_task_done", new { id = plan, line = 9, done = true }));
        Assert.Equal("line (a number) and done (true or false) are required", Refused("set_task_done", new { id = plan, line = "1", done = true }));
        Assert.Equal("line (a number) and done (true or false) are required", Refused("set_task_done", new { id = plan, line = 1.5, done = true }));
        Assert.Equal("Days are YYYY-MM-DD, got 30/10/2071", Refused("list_tasks", new { @from = "30/10/2071" }));
        Assert.Equal("Days are YYYY-MM-DD, got 2071-02-30", Refused("list_tasks", new { to = "2071-02-30" }));
    }

    [Fact]
    public void SearchWithoutTheModelNeverFetchesIt()
    {
        Assert.False(McpServer.Model.HasModel);
        var (word, tag) = (Unique(), Unique());
        var older = Create(new { text = $"Printer quotes\nask about the {word} paper #{tag}" });
        var newer = Create(new { text = $"Toner\n{word} order" });
        var hits = Ok("search_notes", new { query = word.ToUpperInvariant() });
        Assert.Equal([newer, older], Ids(hits));  // newest first, as the notes window's words search
        Assert.Equal($$"""{"id":"{{older}}","score":0.5,"snippet":"Printer quotes ask about the {{word}} paper #{{tag}}","title":"Printer quotes","updated":"{{Updated(older)}}"}""",
            hits[1].GetRawText());
        Assert.Equal([newer], Ids(Ok("search_notes", new { query = word, limit = 1 })));
        var tagged = Ok("search_notes", new { query = "#" + tag });
        Assert.Equal([older], Ids(tagged));
        Assert.Equal(1, tagged[0].GetProperty("score").GetDouble());
        Assert.Equal("[]", Ok("search_notes", new { query = Unique() }).GetRawText());
        Assert.Equal("query is required (a string)", Refused("search_notes"));
        Assert.False(Directory.Exists(Path.Combine(AppPaths.Data, "models")));  // nothing started the model's download
    }

    [Fact]
    public void ReplaceNeedsTheUpdatedAtItRead()
    {
        var id = Create(new { text = "Launch plan" });
        var stamp = Ok("get_note", new { id }).GetProperty("updated_at").GetInt64();
        var changed = $"This note changed since you read it (updated_at is now {stamp}). Call get_note and try again.";
        Assert.Equal(changed, Refused("replace_note_text", new { id, text = "clobbered", expected_updated_at = stamp - 1 }));
        // A stale stamp sent as a string or a float is still checked, and junk is refused rather than ignored.
        Assert.Equal(changed, Refused("replace_note_text", new { id, text = "clobbered", expected_updated_at = $"{stamp - 1}" }));
        Assert.Equal(changed, Refused("replace_note_text", $$"""{"id": "{{id}}", "text": "clobbered", "expected_updated_at": {{stamp - 1}}.0}"""));
        const string junk = "expected_updated_at must be the number updated_at from get_note";
        Assert.Equal(junk, Refused("replace_note_text", new { id, text = "clobbered", expected_updated_at = "yesterday" }));
        Assert.Equal(junk, Refused("replace_note_text", $$"""{"id": "{{id}}", "text": "clobbered", "expected_updated_at": null}"""));
        Assert.Equal("Launch plan", Str(Ok("get_note", new { id }), "text"));

        var replaced = Ok("replace_note_text", new { id, text = "Launch plan v2", expected_updated_at = $"{stamp}.0" });
        Assert.Equal("Launch plan v2", Str(replaced, "title"));
        var digits = replaced.GetProperty("updated_at").GetInt64().ToString(CultureInfo.InvariantCulture);
        Ok("replace_note_text", $$"""{"id": "{{id}}", "text": "v3", "expected_updated_at": {{digits[0]}}.{{digits[1..]}}e{{digits.Length - 1}}}""");  // 1.73e12
        Assert.Equal("text is required (a string)", Refused("replace_note_text", new { id }));
        Ok("replace_note_text", new { id, text = "v4" });  // without expected_updated_at too, as on the Mac
        Assert.Equal("v4", Str(Ok("get_note", new { id }), "text"));
        Assert.Contains(NoteStore.DirtyNotes(int.MaxValue), note => note.Id == id);  // the app's save path: the sync flag
        Assert.Contains(NoteStore.LoadHistory(), snapshot => snapshot.Note.Id == id);  // and the day's snapshot
    }

    [Fact]
    public void PinsColoursAndFolders()
    {
        var folder = new Folder { Name = "Work " + Unique() };
        NoteStore.SaveFolder(folder);
        var host = Unique() + ".example";
        var page = Create(new { text = "Read the caching docs\nISR and the fetch cache", url = $"https://{host}/docs" });
        var updated = Ok("update_note", new { id = page, pinned = true, color = "blue", folder = folder.Name.ToUpperInvariant() });
        var stamp = updated.GetProperty("updated_at").GetInt64();
        Assert.Equal($$"""{"color":"blue","folder":"{{folder.Name}}","id":"{{page}}","pinned":true,"source":"{{host}}","title":"Read the caching docs","updated":"{{Updated(page)}}","updated_at":{{stamp}}}""",
            updated.GetRawText());
        Assert.Equal("color is one of grey, blue, red, yellow, green, pink, purple, cyan, orange, none", Refused("update_note", new { id = page, color = "magenta" }));
        Assert.Equal("Give pinned, starred, color or folder to change", Refused("update_note", new { id = page }));

        Assert.Equal($$"""{"notes":[{"color":"blue","folder":"{{folder.Name}}","id":"{{page}}","pinned":true,"preview":"ISR and the fetch cache","source":"{{host}}","title":"Read the caching docs","updated":"{{Updated(page)}}"}],"total":1}""",
            Ok("list_notes", new { folder = folder.Name }).GetRawText());
        Assert.Equal([page], Ids(Ok("list_notes", new { folder = folder.Id.ToUpperInvariant() }).GetProperty("notes")));  // or by its id
        Assert.Equal([page], Ids(Ok("list_notes", new { source = host.ToUpperInvariant() }).GetProperty("notes")));
        Assert.Equal([page], Ids(Ok("list_notes", new { source = host, pinned = true, updated_since = "2000-01-01" }).GetProperty("notes")));
        Assert.Empty(Ids(Ok("list_notes", new { source = host, starred = true }).GetProperty("notes")));
        Assert.Empty(Ids(Ok("list_notes", new { source = host, updated_since = "2999-01-01T00:00:00Z" }).GetProperty("notes")));
        Assert.Equal("updated_since must be YYYY-MM-DD or ISO 8601, got last week", Refused("list_notes", new { updated_since = "last week" }));
        Assert.StartsWith("No folder \"Nowhere\".", Refused("list_notes", new { folder = "Nowhere" }));
        Assert.Equal($$"""{"id":"{{folder.Id}}","name":"{{folder.Name}}","notes":1}""",
            Ok("list_folders").EnumerateArray().Single(f => Str(f, "id") == folder.Id).GetRawText());

        // Out of the folder, without colour or pin; a millisecond onto updated_at, as every pin or move.
        var plain = Ok("update_note", new { id = page, folder = "", color = "none", pinned = false });
        Assert.Equal(["id", "source", "title", "updated", "updated_at"], plain.EnumerateObject().Select(p => p.Name));
        Assert.Equal(stamp + 1, plain.GetProperty("updated_at").GetInt64());
        Assert.Equal(0, Ok("list_folders").EnumerateArray().Single(f => Str(f, "id") == folder.Id).GetProperty("notes").GetInt32());
    }

    [Fact]
    public void TagsMostUsedFirst()
    {
        var u = Unique();
        Create(new { text = $"one #{u}-b #{u}-c" });
        Create(new { text = $"two #{u}-b #{u}-a" });
        Assert.Equal([$$"""{"count":2,"tag":"{{u}}-b"}""", $$"""{"count":1,"tag":"{{u}}-a"}""", $$"""{"count":1,"tag":"{{u}}-c"}"""],
            Ok("list_tags").EnumerateArray().Where(tag => Str(tag, "tag").StartsWith(u, StringComparison.Ordinal)).Select(tag => tag.GetRawText()));
        Assert.Equal(2, Ok("list_notes", new { tag = $"#{u.ToUpperInvariant()}-B" }).GetProperty("total").GetInt32());  // with or without #, any case
    }

    [Fact]
    public void LockedNotesStayClosed()
    {
        var tag = Unique();
        var id = Create(new { text = $"Secret plan\n- [ ] call the bank @2072-01-05 #{tag}" });
        const string envelope = "mnlock:v1:c2VjcmV0";
        NoteStore.SetLocked(id, envelope, true);
        var note = Ok("get_note", new { id });
        Assert.Equal(["created", "id", "kind", "locked", "title", "updated", "updated_at"], note.EnumerateObject().Select(p => p.Name));
        Assert.Equal(("Locked Note", true), (Str(note, "title"), note.GetProperty("locked").GetBoolean()));
        const string closed = "This note is locked. Its text can only be changed in NoteAnywhere, after unlocking it.";
        Assert.Equal(closed, Refused("append_to_note", new { id, text = "x" }));
        Assert.Equal(closed, Refused("replace_note_text", new { id, text = "x" }));
        Assert.Equal(closed, Refused("set_task_done", new { id, line = 1, done = true }));
        Assert.True(Ok("update_note", new { id, pinned = true }).GetProperty("pinned").GetBoolean());  // as in the app
        Assert.Equal(envelope, NoteStore.LoadAll().Single(n => n.Id == id).Text);

        Assert.Equal("[]", Ok("search_notes", new { query = "#" + tag }).GetRawText());
        Assert.DoesNotContain(Ok("search_notes", new { query = "Locked Note", limit = 50 }).EnumerateArray(), hit => hit.TryGetProperty("locked", out _));  // not even by the title it shows
        Assert.Equal(0, Ok("list_tasks", new { @from = "2072-01-05", to = "2072-01-05" }).GetProperty("total").GetInt32());
        Assert.Equal(0, Ok("list_notes", new { tag }).GetProperty("total").GetInt32());
        var listed = Ok("list_notes", new { pinned = true, limit = 200 }).GetProperty("notes").EnumerateArray().Single(n => Str(n, "id") == id);
        Assert.Equal(["id", "locked", "pinned", "title", "updated"], listed.EnumerateObject().Select(p => p.Name));  // listed, without a preview
    }

    [Fact]
    public void TextComesBackAsWritten()
    {
        const string text = "Café crème, 東京 and 👍 \"quoted\" back\\slash\ttab\u0001";
        var id = Create(new { text });
        Assert.Contains("Café crème, 東京 and 👍", Call("get_note", new { id }).Text);  // as is, not \u escapes: models read this text
        Assert.Equal(text, Str(Ok("get_note", new { id }), "text"));

        // Windows line breaks are kept as the Mac's by every tool that writes text, and the save still counts as landed.
        var lines = Create(new { text = "Plan\r\n- [ ] one" });
        Ok("append_to_note", new { id = lines, text = "- [ ] two\r\n- [ ] three" });
        Assert.Equal("Plan\n- [ ] one\n- [ ] two\n- [ ] three", Str(Ok("get_note", new { id = lines }), "text"));
        Ok("replace_note_text", new { id = lines, text = "New\r\nbody" });
        Assert.Equal("New\nbody", Str(Ok("get_note", new { id = lines }), "text"));
    }

    // MCPServerTests.swift

    [Fact]
    public void TicksOnlyChecklistLines()
    {
        const string text = "Plan\n- [ ] call @2026-10-30\n  * [x] nested\n- plain";
        Assert.Equal("Plan\n- [x] call @2026-10-30\n  * [x] nested\n- plain", McpServer.SettingTask(text, 1, true));
        Assert.Equal("Plan\n- [ ] call @2026-10-30\n  * [ ] nested\n- plain", McpServer.SettingTask(text, 2, false));
        Assert.Null(McpServer.SettingTask(text, 0, true));
        Assert.Null(McpServer.SettingTask(text, 3, true));
        Assert.Null(McpServer.SettingTask(text, 9, true));
        Assert.Null(McpServer.SettingTask(text, -1, true));
    }

    [Fact]
    public void SnippetIsOneLineAroundTheFirstHit()
    {
        var text = new string('a', 100) + "\nThe Printer quote\n" + new string('b', 200);
        var snippet = McpServer.Snippet(text, "printer cost")!;
        Assert.True(snippet.StartsWith('…') && snippet.EndsWith('…') && snippet.Contains("The Printer quote"), snippet);
        Assert.DoesNotContain("\n", snippet);
        Assert.Null(McpServer.Snippet("short note", "nothing here"));
        // Characters as Swift counts them: 60 before the hit, even emoji, and nothing is cut.
        var sixty = string.Concat(Enumerable.Repeat("👍", 59)) + " printer";
        Assert.Equal(sixty, McpServer.Snippet(sixty, "printer"));
        Assert.Equal("…" + sixty, McpServer.Snippet("👍" + sixty, "printer"));
    }

    [Fact]
    public void ReadsDaysAndDateTimes()
    {
        var instant = DateTimeOffset.FromUnixTimeSeconds(1_790_847_000);
        Assert.Equal(instant, McpServer.ParseDate("2026-10-01T09:30:00Z"));
        Assert.Equal(instant, McpServer.ParseDate("2026-10-01T11:30:00+02:00"));
        var day = new DateTime(2026, 10, 1);
        Assert.Equal(new DateTimeOffset(day, TimeZoneInfo.Local.GetUtcOffset(day)), McpServer.ParseDate("2026-10-01"));  // midnight here
        Assert.Null(McpServer.ParseDate("last week"));
        Assert.Null(McpServer.ParseDate("2026-10-01T09:30:00"));  // a time needs its zone, as for the Mac's formatter
        var iso = McpServer.Iso(instant.ToUnixTimeMilliseconds());
        Assert.Matches(@"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(Z|[+-]\d\d:\d\d)$", iso);
        Assert.Equal(instant, DateTimeOffset.Parse(iso, CultureInfo.InvariantCulture));
    }

    /// With the model on disk, as the app leaves it, search finds notes by meaning as the Mac's does.
    [ModelFact]
    public async Task SearchesByMeaningWithTheModel()
    {
        using var model = new Embedder(Path.Combine(Path.GetTempPath(), "noteanywhere-model"));  // EmbedderTests' download
        Assert.NotNull(await model.EmbedAsync("download it, if it isn't here yet"));
        var before = McpServer.Model;
        McpServer.Model = model;
        try
        {
            var fish = Create(new { text = $"Feed the goldfish and clean the aquarium filter {Unique()}" });
            var hits = Ok("search_notes", new { query = "how to look after pets that swim" });
            Assert.Equal(fish, Str(hits[0], "id"));  // no word of the query is in it
            Assert.InRange(hits[0].GetProperty("score").GetDouble(), 0.26, 1);
        }
        finally
        {
            McpServer.Model = before;
        }
    }
}
