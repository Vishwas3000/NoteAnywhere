using System.Collections;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;
using NoteAnywhere.Core.Search;

namespace NoteAnywhere.Core;

/// NoteAnywhere as an MCP server (`NoteAnywhere.exe --mcp`), so Claude, Codex or Gemini can search, read and edit
/// notes: a port of the Mac's MCPServer.swift. stdio, one JSON-RPC message per line. Dual-era: the 2026-07-28 protocol
/// (version and capabilities in each request's `_meta`) and the older `initialize` handshake (2024-11-05 to 2025-11-25)
/// that most clients still speak. There is no delete tool, and a locked note's text is never read or written.
public static partial class McpServer
{
    static readonly string[] Modern = ["2026-07-28"];
    static readonly string[] Legacy = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

    /// The search model, used only once the app has downloaded it: nothing here starts the download.
    internal static Embedder Model { get; set; } = new();

    sealed class ToolError(string message) : Exception(message);

    /// A JSON object whose keys are written sorted, as the Mac writes them: the same tool list byte for byte every
    /// time, which clients can cache.
    sealed class Fields() : SortedDictionary<string, object?>(StringComparer.Ordinal);

    sealed record Tool(string Name, string Description, Fields Properties, Func<JsonElement, object> Run)
    {
        public string[] Required { get; init; } = [];
        public bool ReadOnly { get; init; }
        public bool Destructive { get; init; }

        // Plain schemas (no unions, no additionalProperties): Gemini and Codex accept only a subset of JSON Schema.
        public Fields Spec()
        {
            var schema = new Fields { ["type"] = "object", ["properties"] = Properties };
            if (Required.Length > 0) schema["required"] = Required;
            return new()
            {
                ["name"] = Name, ["description"] = Description, ["inputSchema"] = schema,
                ["annotations"] = ReadOnly ? new Fields { ["readOnlyHint"] = true }
                    : new Fields { ["readOnlyHint"] = false, ["destructiveHint"] = Destructive, ["openWorldHint"] = false },
            };
        }
    }

    /// The server on this process's stdin and stdout, in UTF-8 whatever the console's code page, until the client
    /// closes stdin.
    public static int Run()
    {
        var output = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false));
        // stdout carries protocol messages only: anything else printed (a library's progress, say) goes to stderr.
        Console.SetOut(Console.Error);
        Run(new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false)), output);
        return 0;
    }

    public static void Run(TextReader input, TextWriter output)
    {
        while (input.ReadLine() is { } line)
        {
            if (string.IsNullOrWhiteSpace(line) || Handle(line) is not { } reply) continue;
            try
            {
                output.Write(reply + "\n");  // not WriteLine, which ends lines with "\r\n" on Windows
                output.Flush();
            }
            catch (IOException) { return; }  // the client hung up
        }
    }

    /// One message in, at most one reply out (notifications get none).
    internal static string? Handle(string line)
    {
        using var document = Parse(line);
        try
        {
            return document?.RootElement is { ValueKind: JsonValueKind.Object } message ? Reply(message) : Error(null, -32700, "Parse error");
        }
        catch (InvalidOperationException)  // a string holding half a surrogate pair ("\ud83d"), which the Mac's parser refuses too
        {
            return Error(null, -32700, "Parse error");
        }
    }

    static string? Reply(JsonElement message)
    {
        if (Str(message, "method") is not { } method)
            return Has(message, "id") ? null : Error(null, -32600, "Invalid request");  // a response: we send no requests
        var id = Get(message, "id");
        if (id.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null) return null;  // a notification: initialized, cancelled, …
        var parameters = Get(message, "params");
        var meta = Get(parameters, "_meta");
        var version = Str(meta, "io.modelcontextprotocol/protocolVersion");
        if (version != null)  // modern: every request names its version and capabilities
        {
            if (!Modern.Contains(version))
                return Error(id, -32022, "Unsupported protocol version", new() { ["supported"] = Modern.Concat(Legacy), ["requested"] = version });
            if (Get(meta, "io.modelcontextprotocol/clientCapabilities").ValueKind != JsonValueKind.Object)
                return Error(id, -32602, "Missing _meta.io.modelcontextprotocol/clientCapabilities");
        }
        else if (method == "server/discover")
        {
            return Error(id, -32602, "Missing _meta.io.modelcontextprotocol/protocolVersion");
        }

        Fields result;
        switch (method)
        {
            case "initialize":
                var asked = Str(parameters, "protocolVersion") ?? "";
                result = new()
                {
                    ["protocolVersion"] = Legacy.Contains(asked) ? asked : Legacy[0], ["capabilities"] = new Fields { ["tools"] = new Fields() },
                    ["serverInfo"] = ServerInfo, ["instructions"] = Instructions,
                };
                break;
            case "server/discover":
                result = new() { ["supportedVersions"] = Modern, ["capabilities"] = new Fields { ["tools"] = new Fields() }, ["instructions"] = Instructions };
                break;
            case "ping":
                result = new();
                break;
            case "tools/list":
                result = new() { ["tools"] = Tools.Select(tool => tool.Spec()) };
                break;
            case "tools/call":
                var name = Str(parameters, "name");
                if (Tools.FirstOrDefault(tool => tool.Name == name) is not { } called) return Error(id, -32602, $"Unknown tool: {name}");
                result = Call(called, Get(parameters, "arguments"));
                break;
            default:
                return Error(id, -32601, $"Method not found: {method}");
        }
        if (version != null)
        {
            result["resultType"] = "complete";
            result["_meta"] = new Fields { ["io.modelcontextprotocol/serverInfo"] = ServerInfo };
        }
        return Encode(new Fields { ["jsonrpc"] = "2.0", ["id"] = id, ["result"] = result });
    }

    static readonly Fields ServerInfo = new()
    {
        ["name"] = "NoteAnywhere", ["version"] = typeof(McpServer).Assembly.GetName().Version?.ToString(3) ?? "dev",
    };

    // The Mac's text but for its "a Mac notes app".
    const string Instructions =
        "The user's notes from NoteAnywhere, a Windows notes app. Notes are Markdown; the first line is the title. "
        + "Find notes with search_notes (by meaning and words, or \"#tag\") or list_notes; both return summaries, and "
        + "get_note returns the full text. Dated lines carry @YYYY-MM-DD and checklist items are \"- [ ] \"; list_tasks "
        + "and set_task_done work on them. Prefer append_to_note for additions; replace_note_text rewrites a note and "
        + "needs updated_at from get_note. Nothing can be deleted, and locked notes stay closed.";

    // Tools

    static readonly string[] Colors = [.. Enum.GetValues<NoteColor>().Select(color => color.RawValue), "none"];

    static readonly Tool[] Tools =
    [
        new("search_notes",
            "Find notes by meaning and by exact words (on-device). A query of \"#tag\" lists that tag's notes. Returns summaries with a snippet; read one with get_note.",
            new() { ["query"] = Text("What to look for"), ["limit"] = Number("Most results to return, default 10, up to 50") },
            SearchNotes) { Required = ["query"], ReadOnly = true },
        new("list_notes",
            "List notes, newest edit first, as summaries. Filter by source (an app or site, e.g. \"Slack\" or \"github.com\"), #tag, folder, pinned, starred, or edits since a date.",
            new()
            {
                ["source"] = Text("Part of the app or site name or address"), ["tag"] = Text("A tag, with or without #"),
                ["folder"] = Text("Folder name or id"), ["pinned"] = Flag("Only pinned (true) or unpinned (false) notes"),
                ["starred"] = Flag("Only starred (true) or unstarred (false) notes"),
                ["updated_since"] = Text("YYYY-MM-DD or an ISO 8601 date-time"), ["limit"] = Number("Most notes to return, default 30, up to 200"),
            },
            ListNotes) { ReadOnly = true },
        new("get_note",
            "A note's full Markdown text with its source, folder, tags, dated lines and updated_at (needed by replace_note_text).",
            new() { ["id"] = Text("The note's id") },
            GetNote) { Required = ["id"], ReadOnly = true },
        new("list_tasks",
            "Lines dated with @YYYY-MM-DD across all notes (checklist items are tasks), by day. Open ones only unless include_done.",
            new()
            {
                ["from"] = Text("First day, YYYY-MM-DD"), ["to"] = Text("Last day, YYYY-MM-DD"),
                ["include_done"] = Flag("Also list ticked tasks"), ["limit"] = Number("Most lines to return, default 100, up to 500"),
            },
            ListTasks) { ReadOnly = true },
        new("list_tags", "Every #tag in use with how many notes have it, most used first.", new(), ListTags) { ReadOnly = true },
        new("list_folders", "The folders, with their ids and how many notes each holds.", new(), ListFolders) { ReadOnly = true },
        new("create_note",
            "Create a note from Markdown (first line = title). Plain by default; with url it belongs to that web page and shows there in the browser panel. Notes for apps can't be created from here.",
            new() { ["text"] = Text("The note, in Markdown"), ["url"] = Text("Optional web page the note is about"), ["folder"] = Text("Optional folder name or id") },
            CreateNote) { Required = ["text"] },
        new("append_to_note",
            "Add Markdown to the end of a note, on a new line. The safe way to add to a note.",
            new() { ["id"] = Text("The note's id"), ["text"] = Text("Markdown to add") },
            AppendToNote) { Required = ["id", "text"] },
        new("replace_note_text",
            "Replace a note's whole text. Pass updated_at from get_note as expected_updated_at: if the note changed since, nothing is replaced.",
            new() { ["id"] = Text("The note's id"), ["text"] = Text("The new Markdown text"), ["expected_updated_at"] = Number("updated_at from get_note") },
            ReplaceNoteText) { Required = ["id", "text"], Destructive = true },
        new("update_note",
            "Pin or star a note (or undo either), set its colour label, or move it to a folder. Its text is unchanged.",
            new()
            {
                ["id"] = Text("The note's id"), ["pinned"] = Flag("Pin (true) or unpin (false)"), ["starred"] = Flag("Star (true) or unstar (false)"),
                ["color"] = new Fields { ["type"] = "string", ["enum"] = Colors, ["description"] = "Colour label, or none" },
                ["folder"] = Text("Folder name or id; empty string for no folder"),
            },
            UpdateNote) { Required = ["id"] },
        new("set_task_done",
            "Tick or untick a checklist item (\"- [ ] …\"). line is its 0-based line in the note's text, as list_tasks and get_note's dates give it.",
            new() { ["id"] = Text("The note's id"), ["line"] = Number("0-based line number"), ["done"] = Flag("true ticks it, false unticks it") },
            SetTaskDone) { Required = ["id", "line", "done"] },
    ];

    static List<Fields> SearchNotes(JsonElement args)
    {
        var query = Required(args, "query");
        var folders = FolderNames();
        var notes = NoteStore.LoadAll();
        var limit = Limit(args, 10, 50);
        // Without the model, the words search the notes window shows first, scored as the Mac scores hits without its
        // model: 1 for a tag's note, 0.5 for a note with every word.
        var wordsScore = query.Trim() is var trimmed && trimmed.StartsWith('#') && Note.TagName(trimmed) != null ? 1.0 : 0.5;
        var hits = Model.HasModel
            ? new SearchIndex(Database, Model.EmbedAsync).SearchAsync(query, notes, limit).GetAwaiter().GetResult().Select(hit => (hit.Note, hit.Score))
            : NoteActions.Search(notes.Where(note => !note.Locked), query).Take(limit).Select(note => (Note: note, Score: wordsScore));
        return [.. hits.Select(hit =>
        {
            var s = Summary(hit.Note, folders);
            s["snippet"] = Snippet(hit.Note.Text, query) ?? Prefix(hit.Note.Preview, 160);
            s["score"] = Math.Round(hit.Score * 100, MidpointRounding.AwayFromZero) / 100;
            return s;
        })];
    }

    static Fields ListNotes(JsonElement args)
    {
        IEnumerable<Note> notes = NoteStore.LoadAll();
        if (Str(args, "source") is { Length: > 0 } source)
            notes = notes.Where(note => new[] { note.Label, note.Target, note.ShortSource() }.Any(s => s.Contains(source, StringComparison.CurrentCultureIgnoreCase)));
        if (Str(args, "tag") is { Length: > 0 } tag)
        {
            var name = Note.Lowercased(tag.Trim('#'));
            notes = notes.Where(note => note.HasTag(name));
        }
        if (Str(args, "folder") is { Length: > 0 } folder)
        {
            var id = FolderID(folder);
            notes = notes.Where(note => note.FolderID == id);
        }
        if (Bool(args, "pinned") is { } pinned) notes = notes.Where(note => note.Pinned == pinned);
        if (Bool(args, "starred") is { } starred) notes = notes.Where(note => note.Starred == starred);
        if (Str(args, "updated_since") is { Length: > 0 } since)
        {
            var date = ParseDate(since) ?? throw new ToolError($"updated_since must be YYYY-MM-DD or ISO 8601, got {since}");
            notes = notes.Where(note => note.UpdatedAt >= date.ToUnixTimeMilliseconds());
        }
        var found = notes.ToList();
        var folders = FolderNames();
        var shown = found.OrderByDescending(note => note.UpdatedAt).Take(Limit(args, 30, 200)).Select(note =>
        {
            var s = Summary(note, folders);
            if (note.Preview is { Length: > 0 } preview) s["preview"] = Prefix(preview, 120);
            return s;
        });
        return new() { ["total"] = found.Count, ["notes"] = shown.ToList() };
    }

    static Fields GetNote(JsonElement args)
    {
        var note = Fetch(Required(args, "id"));
        var r = Summary(note, FolderNames());
        r["kind"] = note.Kind == NoteKind.App ? "app" : note.HasSource ? "website" : "plain";
        if (note.HasSource)
        {
            r["target"] = note.Target;
            r["label"] = note.Label;
        }
        r["created"] = Iso(note.CreatedAt);
        r["updated_at"] = Stamp(note);
        if (!note.Locked)
        {
            r["text"] = note.Text;
            r["tags"] = note.Tags;
            r["dates"] = note.Dates.Select(line => Dated(line, null)).ToList();
        }
        return r;
    }

    static Fields ListTasks(JsonElement args)
    {
        string? from = Str(args, "from"), to = Str(args, "to");
        foreach (var day in new[] { from, to }.OfType<string>())
            if (!DatedLine.IsDay(day)) throw new ToolError($"Days are YYYY-MM-DD, got {day}");
        var includeDone = Bool(args, "include_done") ?? false;
        var notes = NoteStore.LoadAll();
        var titles = notes.ToDictionary(note => note.Id, note => note.Title);
        var items = notes.SelectMany(note => note.Dates)
            .Where(item => (from == null || string.CompareOrdinal(item.Day, from) >= 0) && (to == null || string.CompareOrdinal(item.Day, to) <= 0)
                && (includeDone || !item.Done))
            .OrderBy(item => item.Day, StringComparer.Ordinal).ThenBy(item => item.NoteID, StringComparer.Ordinal).ThenBy(item => item.Line)
            .ToList();
        return new() { ["total"] = items.Count, ["lines"] = items.Take(Limit(args, 100, 500)).Select(item => Dated(item, titles[item.NoteID])).ToList() };
    }

    static List<Fields> ListTags(JsonElement args) =>
        [.. NoteActions.TagCounts(NoteStore.LoadAll()).Select(tag => new Fields { ["tag"] = tag.Tag, ["count"] = tag.Count })];

    static List<Fields> ListFolders(JsonElement args)
    {
        var notes = NoteStore.LoadAll();
        return [.. NoteStore.Folders().Select(folder => new Fields
        {
            ["id"] = folder.Id, ["name"] = folder.Name, ["notes"] = notes.Count(note => note.FolderID == folder.Id),
        })];
    }

    static Fields CreateNote(JsonElement args)
    {
        var body = Required(args, "text");
        var target = "";
        if (Str(args, "url") is { Length: > 0 } url)
        {
            target = Uri.TryCreate(url.Contains("://") ? url : "https://" + url, UriKind.Absolute, out var page) ? Note.PageTarget(page) : "";
            if (target.Length == 0) throw new ToolError("url must be a web address, like https://github.com/apple/swift");
        }
        var folder = Str(args, "folder") is { Length: > 0 } name ? FolderID(name) : null;
        var note = new Note { Kind = NoteKind.Url, Target = target, Label = target.Split('/')[0], Text = body };
        NoteStore.Save(note);
        if (folder != null) NoteStore.SaveMeta(note with { FolderID = folder });
        var saved = Fetch(note.Id);
        return new() { ["id"] = saved.Id, ["title"] = saved.Title, ["updated_at"] = Stamp(saved) };
    }

    static Fields AppendToNote(JsonElement args)
    {
        var note = FetchWritable(Required(args, "id"));
        var addition = Required(args, "text");
        return Save(note with { Text = note.Text.Length == 0 ? addition : note.Text + (note.Text.EndsWith('\n') ? "" : "\n") + addition });
    }

    static Fields ReplaceNoteText(JsonElement args)
    {
        var note = FetchWritable(Required(args, "id"));
        if (Has(args, "expected_updated_at"))
        {
            // Models send numbers as 1.73e12, 1730000000000.0 or "1730000000000"; any of them is checked, never skipped.
            var raw = Get(args, "expected_updated_at");
            double? expected = raw.ValueKind switch
            {
                JsonValueKind.Number when raw.TryGetDouble(out var number) => number,
                JsonValueKind.String when double.TryParse(raw.GetString(), NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint
                    | NumberStyles.AllowExponent, CultureInfo.InvariantCulture, out var number) => number,
                _ => null,
            };
            if (expected is not { } sent || !double.IsFinite(sent)) throw new ToolError("expected_updated_at must be the number updated_at from get_note");
            if (Math.Round(sent, MidpointRounding.AwayFromZero) != Stamp(note))
                throw new ToolError($"This note changed since you read it (updated_at is now {Stamp(note)}). Call get_note and try again.");
        }
        return Save(note with { Text = Required(args, "text") });
    }

    static Fields UpdateNote(JsonElement args)
    {
        var note = Fetch(Required(args, "id"));  // a locked note can be pinned or moved, as in the app
        if (!new[] { "pinned", "starred", "color", "folder" }.Any(key => Has(args, key)))
            throw new ToolError("Give pinned, starred, color or folder to change");
        if (Bool(args, "pinned") is { } pinned) note = note with { Pinned = pinned };
        if (Bool(args, "starred") is { } starred) note = note with { Starred = starred };
        if (Str(args, "color") is { } color)
        {
            if (!Colors.Contains(color)) throw new ToolError($"color is one of {string.Join(", ", Colors)}");
            note = note with { Color = NoteColor.FromRawValue(color) };
        }
        if (Str(args, "folder") is { } folder) note = note with { FolderID = folder.Length == 0 ? null : FolderID(folder) };
        NoteStore.SaveMeta(note);
        var saved = Fetch(note.Id);
        var summary = Summary(saved, FolderNames());
        summary["updated_at"] = Stamp(saved);
        return summary;
    }

    static Fields SetTaskDone(JsonElement args)
    {
        var note = FetchWritable(Required(args, "id"));
        if (Integer(args, "line") is not { } line || Bool(args, "done") is not { } done)
            throw new ToolError("line (a number) and done (true or false) are required");
        var ticked = SettingTask(note.Text, line, done) ?? throw new ToolError($"Line {line} isn't a checklist item (\"- [ ] …\")");
        if (ticked == note.Text) return new() { ["id"] = note.Id, ["updated_at"] = Stamp(note) };
        return Save(note with { Text = ticked });
    }

    // Helpers

    static Fields Text(string description) => new() { ["type"] = "string", ["description"] = description };
    static Fields Number(string description) => new() { ["type"] = "integer", ["description"] = description };
    static Fields Flag(string description) => new() { ["type"] = "boolean", ["description"] = description };

    static JsonElement Get(JsonElement o, string key) => o.ValueKind == JsonValueKind.Object && o.TryGetProperty(key, out var value) ? value : default;
    static bool Has(JsonElement o, string key) => Get(o, key).ValueKind != JsonValueKind.Undefined;
    static string? Str(JsonElement o, string key) => Get(o, key) is { ValueKind: JsonValueKind.String } value ? value.GetString() : null;
    static bool? Bool(JsonElement o, string key) => Get(o, key).ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => null };

    // Swift's `as? Int` on a JSON number: a whole number, written 3 or 3.0.
    static long? Integer(JsonElement o, string key) =>
        Get(o, key) is { ValueKind: JsonValueKind.Number } value && value.TryGetDouble(out var n) && n == Math.Floor(n) && n is >= long.MinValue and < long.MaxValue
            ? (long)n : null;

    static string Required(JsonElement args, string key) => Str(args, key) ?? throw new ToolError($"{key} is required (a string)");

    static int Limit(JsonElement args, int fallback, int most) => (int)Math.Clamp(Integer(args, "limit") ?? fallback, 1, most);

    static string Database => new SqliteConnectionStringBuilder { DataSource = NoteStore.DatabasePath }.ToString();

    /// updated_at as whole milliseconds: what replace_note_text compares, so a model never has to copy a fraction.
    internal static long Stamp(Note note) => (long)Math.Round(note.UpdatedAt, MidpointRounding.AwayFromZero);

    // shortcut: reads every note to find one; fine for thousands of notes, add a by-id query if that ever shows up.
    static Note Fetch(string id) =>
        NoteStore.LoadAll().FirstOrDefault(note => note.Id == Note.Lowercased(id))  // ids given out before D76 were uppercase
        ?? throw new ToolError($"No note with id {id}. Find ids with search_notes or list_notes.");

    static Note FetchWritable(string id) => Fetch(id) is { Locked: false } note ? note
        : throw new ToolError("This note is locked. Its text can only be changed in NoteAnywhere, after unlocking it.");

    /// Saves new text the way the app does (snapshot, sync flag), then checks it landed.
    static Fields Save(Note note)
    {
        note = note with { Text = note.Text.Replace("\r\n", "\n"), UpdatedAt = Note.Now() };  // the store keeps the Mac's line breaks
        NoteStore.Save(note);
        var saved = Fetch(note.Id);
        if (saved.Text != note.Text) throw new ToolError("The note wasn't saved; it may have been locked or deleted meanwhile.");
        return new() { ["id"] = saved.Id, ["title"] = saved.Title, ["updated_at"] = Stamp(saved) };
    }

    static Dictionary<string, string> FolderNames() => NoteStore.Folders().ToDictionary(folder => folder.Id, folder => folder.Name);

    static string FolderID(string nameOrID)
    {
        var folders = NoteStore.Folders();
        var folder = folders.FirstOrDefault(f => f.Id == Note.Lowercased(nameOrID))
            ?? folders.FirstOrDefault(f => string.Equals(f.Name, nameOrID, StringComparison.InvariantCultureIgnoreCase))
            ?? throw new ToolError($"No folder \"{nameOrID}\". Folders: {string.Join(", ", folders.Select(f => f.Name))}");
        return folder.Id;
    }

    static Fields Summary(Note note, Dictionary<string, string> folders)
    {
        var s = new Fields { ["id"] = note.Id, ["title"] = note.Title, ["updated"] = Iso(note.UpdatedAt) };
        if (note.HasSource) s["source"] = note.ShortSource();
        if (note.Pinned) s["pinned"] = true;
        if (note.Starred) s["starred"] = true;
        if (note.Color is { } color) s["color"] = color.RawValue;
        if (note.FolderID is { } id && folders.TryGetValue(id, out var folder)) s["folder"] = folder;
        if (note.Locked) s["locked"] = true;
        return s;
    }

    static Fields Dated(DatedLine item, string? title)
    {
        var t = new Fields { ["day"] = item.Day, ["text"] = item.Text, ["line"] = item.Line };
        if (item.IsTask)
        {
            t["task"] = true;
            t["done"] = item.Done;
        }
        if (title != null)
        {
            t["note_id"] = item.NoteID;
            t["note_title"] = title;
        }
        return t;
    }

    /// The text with the checklist item on `line` ticked or not; null if that line isn't a checklist item.
    internal static string? SettingTask(string text, long line, bool done)
    {
        var lines = text.Split('\n');
        if (line < 0 || line >= lines.Length || TaskBox().Match(lines[line]) is not { Success: true } box) return null;
        var mark = box.Groups[1];
        lines[line] = lines[line][..mark.Index] + (done ? "x" : " ") + lines[line][(mark.Index + mark.Length)..];
        return string.Join("\n", lines);
    }

    /// Up to ~160 characters around the first word of the query found in the text, on one line. Characters are counted
    /// as Swift counts them, so an emoji or an accented letter is one.
    internal static string? Snippet(string text, string query)
    {
        foreach (var word in SearchIndex.Words(query.ToLowerInvariant()))
        {
            var at = CultureInfo.InvariantCulture.CompareInfo.IndexOf(text, word, CompareOptions.IgnoreCase, out var length);
            if (at < 0) continue;
            var starts = StringInfo.ParseCombiningCharacters(text);
            var first = Array.FindLastIndex(starts, s => s <= at);
            var after = Array.FindIndex(starts, s => s >= at + length) is var next and >= 0 ? next : starts.Length;
            var start = starts[Math.Max(first - 60, 0)];
            var end = after + 100 < starts.Length ? starts[after + 100] : text.Length;
            var flat = string.Join(" ", text[start..end].Split(Newlines, StringSplitOptions.RemoveEmptyEntries));
            return (start > 0 ? "…" : "") + flat + (end < text.Length ? "…" : "");
        }
        return null;
    }

    static readonly char[] Newlines = ['\n', '\v', '\f', '\r', '\u0085', '\u2028', '\u2029'];  // Swift's Character.isNewline

    /// Swift's prefix: the first `count` characters as a person counts them.
    static string Prefix(string text, int count)
    {
        var characters = new StringInfo(text);
        return characters.LengthInTextElements <= count ? text : characters.SubstringByTextElements(0, count);
    }

    /// "2026-10-30T14:05:00+01:00", in this PC's time zone: the Mac's ISO8601DateFormatter, "Z" for UTC.
    internal static string Iso(double ms)
    {
        var time = DateTimeOffset.UnixEpoch.AddMilliseconds(ms).ToLocalTime();
        return time.ToString("yyyy-MM-dd'T'HH:mm:ss", CultureInfo.InvariantCulture)
            + (time.Offset == TimeSpan.Zero ? "Z" : time.ToString("zzz", CultureInfo.InvariantCulture));
    }

    /// An ISO 8601 date-time with its zone, or a day, which starts at midnight here.
    internal static DateTimeOffset? ParseDate(string text) =>
        DateTimeOffset.TryParseExact(text, ["yyyy-MM-dd'T'HH:mm:sszzz", "yyyy-MM-dd'T'HH:mm:ss'Z'"], CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal, out var time) ? time
        : DateTimeOffset.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out var day) ? day
        : null;

    [GeneratedRegex(@"^\s*[-*+]\s+\[([ xX])\]")]
    private static partial Regex TaskBox();

    // JSON-RPC

    static JsonDocument? Parse(string line)
    {
        try { return JsonDocument.Parse(line); }
        catch (JsonException) { return null; }
    }

    static Fields Call(Tool tool, JsonElement args)
    {
        string text;
        var failed = false;
        try
        {
            text = Encode(tool.Run(args));
        }
        catch (Exception e)  // a sentence for the model, as the Mac answers any error a tool throws
        {
            text = e.Message;
            failed = true;
        }
        return new() { ["content"] = new[] { new Fields { ["type"] = "text", ["text"] = text } }, ["isError"] = failed };
    }

    static string Error(object? id, int code, string message, Fields? data = null)
    {
        var error = new Fields { ["code"] = code, ["message"] = message };
        if (data != null) error["data"] = data;
        return Encode(new Fields { ["jsonrpc"] = "2.0", ["id"] = id, ["error"] = error });
    }

    /// JSON as the Mac's JSONSerialization writes it: keys sorted, and "/" and every character beyond ASCII as they
    /// are, so a model reads "Café 👍" in a note and not \u escapes. (System.Text.Json escapes emoji with any encoder.)
    static string Encode(object? value) => value switch
    {
        null => "null",
        bool flag => flag ? "true" : "false",
        string text => Quote(text),
        JsonElement raw => raw.GetRawText(),
        Fields fields => "{" + string.Join(",", fields.Select(field => Quote(field.Key) + ":" + Encode(field.Value))) + "}",
        IEnumerable items => "[" + string.Join(",", items.Cast<object?>().Select(Encode)) + "]",
        IFormattable number => number.ToString(null, CultureInfo.InvariantCulture),
        _ => throw new ArgumentException($"{value.GetType()} isn't JSON"),
    };

    static string Quote(string text)
    {
        var quoted = new StringBuilder(text.Length + 2).Append('"');
        foreach (var c in text)
        {
            if (c is >= ' ' and not ('"' or '\\')) quoted.Append(c);
            else quoted.Append(c switch
            {
                '"' => "\\\"", '\\' => "\\\\", '\n' => "\\n", '\r' => "\\r", '\t' => "\\t", '\b' => "\\b", '\f' => "\\f",
                _ => $"\\u{(int)c:x4}",
            });
        }
        return quoted.Append('"').ToString();
    }
}
