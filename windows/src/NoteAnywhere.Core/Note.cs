using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace NoteAnywhere.Core;

// A port of Sources/MemoryNotes/Note.swift (the model and its text helpers); NoteStore.cs holds the rest of that file.

public enum NoteKind { App, Url }

/// Colour labels, the same set as Chrome's tab groups.
public enum NoteColor { Grey, Blue, Red, Yellow, Green, Pink, Purple, Cyan, Orange }

/// Swift's raw values, "app" and "url", as SQLite, sync and the browser spell them.
public static class NoteKindRawValue
{
    extension(NoteKind kind)
    {
        public string RawValue => kind.ToString().ToLowerInvariant();
        public static NoteKind? FromRawValue(string? raw) => Enum.GetValues<NoteKind>().Where(k => k.RawValue == raw).Select(k => (NoteKind?)k).FirstOrDefault();
    }
}

/// Swift's raw values, "grey" to "orange".
public static class NoteColorRawValue
{
    extension(NoteColor color)
    {
        public string RawValue => color.ToString().ToLowerInvariant();
        public static NoteColor? FromRawValue(string? raw) => Enum.GetValues<NoteColor>().Where(c => c.RawValue == raw).Select(c => (NoteColor?)c).FirstOrDefault();
    }
}

[JsonConverter(typeof(NoteJson))]
public sealed partial record Note
{
    public string Id { get; init; } = NewID();
    public required NoteKind Kind { get; init; }
    /// Bundle id for apps, "host/path" for websites.
    public required string Target { get; init; }
    public required string Label { get; init; }
    public string Text { get; init; } = "";
    public double CreatedAt { get; init; } = Now();
    public double UpdatedAt { get; init; } = Now();
    public bool Pinned { get; init; }
    /// Starred notes stay where they are in the list; the "Starred" filter shows only them (pinned ones go on top).
    public bool Starred { get; init; }
    public string? FolderID { get; init; }
    public NoteColor? Color { get; init; }
    /// The text is an encrypted envelope (see NoteLock); title, preview, tags and dates stay hidden.
    public bool Locked { get; init; }

    /// Lowercase, as the sync server's uuid columns return ids (D76).
    internal static string NewID() => Guid.NewGuid().ToString();
    /// Milliseconds since 1970, as every time is kept: SQLite, the server, JSON.
    internal static double Now() => (DateTime.UtcNow - DateTime.UnixEpoch).TotalMilliseconds;

    /// The first line without Markdown, like the title Apple Notes shows in its list.
    public string Title => Locked ? "Locked Note" : PlainLines(1).FirstOrDefault() ?? "New Note";
    /// What follows the title, flattened to one line.
    public string Preview => Locked ? "" : string.Join(" ", PlainLines(5).Skip(1));
    public DateTimeOffset Edited => DateTimeOffset.UnixEpoch.AddMilliseconds(UpdatedAt);
    /// A note can stand alone: no app or website, stored as a website note without an address.
    public bool HasSource => Target.Length > 0;

    public List<string> Tags => Locked ? [] : TagsIn(Text);

    /// Obsidian-style #tags, lowercased, in order of first use; a tag needs a letter ("#2024" isn't one) and doesn't count in code or a link's address.
    public static List<string> TagsIn(string text)
    {
        var inFence = false;
        HashSet<string> seen = [];
        List<string> found = [];
        foreach (var line in text.Split('\n'))
        {
            if (line.StartsWith("```", StringComparison.Ordinal)) { inFence = !inFence; continue; }
            if (inFence || !line.Contains('#')) continue;
            var prose = CodeOrAddress.Replace(line, " ");
            foreach (Match match in Tag.Matches(prose))
            {
                var tag = Lowercased(match.Groups[1].Value).Trim('/');
                if (tag.Length > 0 && seen.Add(tag.Normalize())) found.Add(tag);
            }
        }
        return found;
    }

    // Tag chips and related notes (D77). Tags stay "#tag" text, so they sync and show everywhere as before.

    /// What "+ Tag" makes of what you type: "Project X" → "project-x", "#Project/X" → "project/x"; null if it can't be a tag.
    public static string? TagName(string typed)
    {
        var words = typed.Trim(Whitespaces).TrimStart('#').Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var name = Lowercased(string.Join("-", words));
        return TagsIn("#" + name) is [var only] && Same(only, name) ? name : null;
    }

    /// The text with #tag added where it disturbs nothing: after a last line of only tags, else on a new last line.
    public static string Adding(string tag, string text)
    {
        if (TagsIn(text).Any(t => Same(t, tag))) return text;
        var lines = text.Split('\n');
        var last = Array.FindLastIndex(lines, line => line.Trim(Whitespaces).Length > 0);
        if (last >= 0 && IsTagLine(lines[last]))
        {
            lines[last] += " #" + tag;
            return string.Join("\n", lines);
        }
        if (text.Trim(WhitespacesAndNewlines).Length == 0) return "#" + tag;
        return text + (text.EndsWith('\n') ? "\n" : "\n\n") + "#" + tag;
    }

    /// The text without #tag: a line of only tags loses it, and goes with the blank line above once empty; in writing only the "#" goes.
    public static string Removing(string tag, string text)
    {
        var inFence = false;
        List<string> kept = [];
        foreach (var line in text.Split('\n'))
        {
            var fence = line.StartsWith("```", StringComparison.Ordinal);
            if (fence) inFence = !inFence;
            if (fence || inFence || !line.Contains('#')) { kept.Add(line); continue; }
            if (IsTagLine(line))
            {
                var rest = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Where(word => !(TagsIn(word) is [var only] && Same(only, tag))).ToList();
                if (rest.Count > 0) kept.Add(string.Join(" ", rest));
                else if (kept.Count > 0 && kept[^1].Trim(Whitespaces).Length == 0) kept.RemoveAt(kept.Count - 1);
                continue;
            }
            kept.Add(CodeAddressOrTag.Replace(line, m =>
                m.Groups[1].Success || !Same(Lowercased(m.Groups[3].Value).Trim('/'), tag) ? m.Value : m.Groups[2].Value + m.Groups[3].Value));
        }
        return string.Join("\n", kept);
    }

    /// "#noteanywhere #bug": a line of only tags, where "+ Tag" adds them.
    static bool IsTagLine(string line)
    {
        var words = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        return words.Length > 0 && words.All(word => word.StartsWith('#') && TagsIn(word).Count == 1);
    }

    /// Other notes with any of this note's tags: most tags in common first, then the most recently edited.
    /// shortcut: parses every note's tags per call, fine for thousands of notes; keep a tag index if libraries outgrow it.
    public static List<(Note Note, List<string> Shared)> Related(Note note, IEnumerable<Note> notes, int limit = 8)
    {
        var mine = note.Tags.Select(tag => tag.Normalize()).ToHashSet();
        if (mine.Count == 0) return [];
        return [.. notes.Where(other => other.Id != note.Id)
            .Select(other => (Note: other, Shared: other.Tags.Where(tag => mine.Contains(tag.Normalize())).ToList()))
            .Where(match => match.Shared.Count > 0)
            .OrderByDescending(match => match.Shared.Count).ThenByDescending(match => match.Note.UpdatedAt)
            .Take(limit)];
    }

    /// Lines with a date, "@2026-10-30" (the editor's) or Obsidian Tasks' "📅 2026-10-30"; a checklist line is a task. The calendar puts each on its day.
    public List<DatedLine> Dates
    {
        get
        {
            if (Locked) return [];
            var inFence = false;
            List<DatedLine> found = [];
            var lines = Text.Split('\n');
            for (var index = 0; index < lines.Length; index++)
            {
                var line = lines[index];
                if (line.StartsWith("```", StringComparison.Ordinal)) { inFence = !inFence; continue; }
                if (inFence || !(line.Contains('@') || line.Contains("📅", StringComparison.Ordinal))) continue;
                var prose = CodeSpan.Replace(line, " ");
                // "@2026-12-03 - @2026-12-06" (or –, —, "to") is every day between; "{red}" after either date is the event's own colour (D67).
                var spans = DateRange.Matches(prose)
                    .Select(m => (First: m.Groups[1].Value, Last: m.Groups[3].Value,
                        Color: NoteColor.FromRawValue(m.Groups[2].Success ? m.Groups[2].Value : m.Groups[4].Success ? m.Groups[4].Value : "")))
                    .Where(span => DatedLine.IsDay(span.First) && DatedLine.IsDay(span.Last) && span.First != span.Last)
                    .Select(span => string.CompareOrdinal(span.First, span.Last) < 0 ? span : (First: span.Last, Last: span.First, span.Color))
                    .ToList();
                var rest = spans.Count == 0 ? prose : DateRange.Replace(prose, " ");
                Dictionary<string, NoteColor?> days = [];  // a date twice on a line is one event; the first colour given wins
                foreach (Match m in LoneDate.Matches(rest))
                {
                    var day = m.Groups[1].Value;
                    if (!DatedLine.IsDay(day)) continue;
                    var color = m.Groups[2].Success ? NoteColor.FromRawValue(m.Groups[2].Value) : null;
                    if (!days.TryGetValue(day, out var had) || had == null) days[day] = color;
                }
                if (days.Count == 0 && spans.Count == 0) continue;
                var task = TaskBox.Match(line);
                var words = Spaces.Replace(Plain(AnyDate.Replace(rest, "")), " ");
                DatedLine Dated(string day, (string First, string Last)? span, NoteColor? color) =>
                    new(Id, index, day, words.Length == 0 ? Title : words, task.Success, task.Success && task.Groups[1].Value != " ",
                        span?.First, span?.Last, color);
                foreach (var (day, color) in days.OrderBy(d => d.Key, StringComparer.Ordinal)) found.Add(Dated(day, null, color));
                foreach (var span in spans) found.AddRange(DatedLine.Days(span.First, span.Last).Select(day => Dated(day, (span.First, span.Last), span.Color)));
            }
            return found;
        }
    }

    /// True for "#project" on a note tagged #project or #project/notes, like Obsidian's tag search.
    public bool HasTag(string tag) => Tags.Any(t => Same(t, tag) || t.Normalize().StartsWith(tag.Normalize() + "/", StringComparison.Ordinal));

    /// The first `limit` non-empty lines as plain text; the sidebar asks for every note's title and preview.
    List<string> PlainLines(int limit)
    {
        var inFence = false;
        List<string> found = [];
        foreach (var line in Text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            if (found.Count == limit) break;
            if (line.StartsWith("```", StringComparison.Ordinal)) { inFence = !inFence; continue; }
            if (!inFence && line.StartsWith("↖ [", StringComparison.Ordinal) && line.Contains("](note://", StringComparison.Ordinal)) continue;  // a page's way back, not its content
            var plain = inFence ? line.Trim(Whitespaces) : Plain(line);
            if (plain.Length > 0) found.Add(plain);
        }
        return found;
    }

    /// One line of Markdown as plain text: no heading/list/quote/checkbox markers, emphasis, code ticks or link targets.
    public static string Plain(string line)
    {
        // Every pattern below needs one of these, or a list number; plain prose skips the regexes.
        var start = line.AsSpan().TrimStart();
        if (line.AsSpan().IndexOfAny("#>-*+_~`[|@") < 0 && !line.Contains("📅", StringComparison.Ordinal) && !(start.Length > 0 && char.IsNumber(start[0])))
            return line.Trim(Whitespaces);
        // A link card is a callout, "> [!bookmark] [Title](url)"; the marker isn't text.
        var plain = LineMarkers.Replace(line, "");
        plain = RuleOrTableSeparator.Replace(plain, "");
        plain = LinkOrImage.Replace(plain, "$1");
        plain = EmphasisMarks.Replace(plain, "");
        plain = Italic.Replace(plain, "$1");  // *italic*, but not "2 * 3"
        plain = TableBar.Replace(plain, "  ");
        plain = PlainDate.Replace(plain, m => DatedLine.IsDay(m.Groups[1].Value) ? DateStyle.Format(m.Groups[1].Value) : m.Value);
        return plain.Trim(Whitespaces);
    }

    /// A website note's target for a page, as the browser extension makes it ("github.com/vercel/next.js"), keeping a query that names the page (D70).
    public static string PageTarget(Uri url)
    {
        if (!url.IsAbsoluteUri || url.Scheme is not ("http" or "https") || url.Host.Length == 0) return "";
        var path = url.AbsolutePath;  // still encoded, like location.pathname
        if (path.EndsWith('/')) path = path[..^1];
        var host = url.HostNameType == UriHostNameType.IPv6 ? url.Host : url.IdnHost;  // punycode, as location.host spells "münchen.de"
        var site = host.StartsWith("www.", StringComparison.Ordinal) ? host[4..] : host;
        return site + (url.IsDefaultPort ? "" : ":" + url.Port) + path + PageQuery(site, path, url.Query);
    }

    /// "?v=9GHCiiDLHQ4" where the query names the page (a YouTube video or search, a Google search), as queryName in extension/content.js.
    static string PageQuery(string host, string path, string query)
    {
        string? name = (host, path) switch
        {
            ("youtube.com", "/watch") => "v",
            ("youtube.com", "/results") => "search_query",
            (_, "/search") when host.StartsWith("google.", StringComparison.Ordinal) => "q",
            _ => null,
        };
        var items = query.Length > 0 ? query[1..].Split('&').Select(item => item.Split('=', 2)) : [];
        if (name == null || items.FirstOrDefault(item => item[0] == name) is not [_, var raw]
            || RemovingPercentEncoding(raw.Replace('+', ' ')) is not { Length: > 0 } value) return "";
        return "?" + name + "=" + string.Concat(Encoding.UTF8.GetBytes(value).Select(b => UriComponent.Contains((char)b) ? ((char)b).ToString() : $"%{b:X2}"));
    }

    const string UriComponent = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()";

    /// Foundation's removingPercentEncoding: null for a stray "%", or for bytes that aren't UTF-8.
    static string? RemovingPercentEncoding(string text)
    {
        List<byte> bytes = [];
        for (var i = 0; i < text.Length;)
        {
            if (text[i] == '%')
            {
                if (i + 3 > text.Length || !byte.TryParse(text.AsSpan(i + 1, 2), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var b)) return null;
                bytes.Add(b);
                i += 3;
                continue;
            }
            var end = text.IndexOf('%', i) is var next and >= 0 ? next : text.Length;
            bytes.AddRange(Encoding.UTF8.GetBytes(text[i..end]));
            i = end;
        }
        try { return new UTF8Encoding(false, throwOnInvalidBytes: true).GetString([.. bytes]); }
        catch (DecoderFallbackException) { return null; }
    }

    /// Swift's lowercased(): .NET's invariant lowercasing agrees on every character but "İ", which Swift makes "i" and a combining dot.
    internal static string Lowercased(string text) => text.Replace("\U00000130", "i\U00000307", StringComparison.Ordinal).ToLowerInvariant();

    /// Swift's String ==, which holds for canonically equivalent text: "é" and "e" with a combining accent are one tag.
    static bool Same(string a, string b) => a.Normalize() == b.Normalize();

    // CharacterSet.whitespaces and .whitespacesAndNewlines: both hold the zero-width space, and .NET's Trim() also takes newlines.
    static readonly char[] Whitespaces = [.. Enumerable.Range(0, 0x10000).Select(c => (char)c)
        .Where(c => c is '\t' or '\U0000200B' || char.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator)];
    static readonly char[] WhitespacesAndNewlines = [.. Enumerable.Range(0, 0x10000).Select(c => (char)c).Where(c => c == '\U0000200B' || char.IsWhiteSpace(c))];

    // Swift's \w, on whole grapheme clusters: letters with their marks and joiners, numbers, "_", Ⓐ; .NET's misses Hindi's vowel signs, Persian's joiner, "²".
    internal const string Word = "\\p{L}\\p{M}\\p{N}_\\u200C\\u200D\\u24B6-\\u24E9";
    // Swift's [^\W\d], a tag's letter: its \d is any number, these CJK numerals too (一, 十, 百, 京…), from Unihan data .NET doesn't carry.
    const string Letter = "\\p{L}\\p{M}_\\u200C\\u200D\\u24B6-\\u24E9-[\\u3405\\u3483\\u382A\\u3B4D\\u4E00\\u4E03\\u4E07\\u4E09\\u4E24\\u4E5D\\u4E8C"
        + "\\u4E94\\u4E96\\u4EAC\\u4EBF\\u4EC0\\u4EDF\\u4EE8\\u4F0D\\u4F70\\u4FE9\\u5006\\u5104\\u5146\\u5169\\u516B\\u516D\\u5341\\u5343-\\u5345"
        + "\\u534C\\u53C1-\\u53C4\\u56DB\\u58F1\\u58F9\\u5E7A\\u5EFE\\u5EFF\\u5F0C-\\u5F0E\\u5F10\\u62D0\\u62FE\\u634C\\u67D2\\u6D1E\\u6F06\\u7396"
        + "\\u767E\\u7695\\u79ED\\u8086\\u842C\\u8CAE\\u8CB3\\u8D30\\u920E\\u94A9\\u9621\\u9646\\u964C\\u9678\\u96F6\\uF96B\\uF973\\uF978\\uF9B2"
        + "\\uF9D1\\uF9D3\\uF9FD]";

    [GeneratedRegex(@"`[^`]*`|\]\([^)]*\)|<[^>]*>")]  // code spans, link targets, autolinks
    private static partial Regex CodeOrAddress { get; }
    [GeneratedRegex($$"""(?:^|[\s(\[{,;:!?])#([{{Word}}\-/]*[{{Letter}}][{{Word}}\-/]*)""")]
    private static partial Regex Tag { get; }
    [GeneratedRegex($$"""(`[^`]*`|\]\([^)]*\)|<[^>]*>)|(^|[\s(\[{,;:!?])#([{{Word}}\-/]*[{{Letter}}][{{Word}}\-/]*)""")]
    private static partial Regex CodeAddressOrTag { get; }
    [GeneratedRegex("`[^`]*`")]
    private static partial Regex CodeSpan { get; }
    [GeneratedRegex($$"""(?:@|📅\s?)(\d{4}-\d{2}-\d{2})(?:\{([a-z]+)\})?\s*(?:-|–|—|to)\s*(?:@|📅\s?)(\d{4}-\d{2}-\d{2})(?:\{([a-z]+)\})?(?![{{Word}}\-])""")]
    private static partial Regex DateRange { get; }
    [GeneratedRegex($$"""(?:^|[\s(\[])(?:@|📅\s?)(\d{4}-\d{2}-\d{2})(?:\{([a-z]+)\})?(?![{{Word}}\-])""")]
    private static partial Regex LoneDate { get; }
    [GeneratedRegex(@"^\s*[-*+]\s+\[([ xX])\]\s")]
    private static partial Regex TaskBox { get; }
    [GeneratedRegex(@"(?:@|📅\s?)\d{4}-\d{2}-\d{2}(?:\{[a-z]+\})?")]
    private static partial Regex AnyDate { get; }
    [GeneratedRegex(@"\s{2,}")]
    private static partial Regex Spaces { get; }
    [GeneratedRegex(@"^\s*(#{1,6}\s+|>\s*(?:\[!bookmark\]\s*)?|[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|\d+[.)]\s+)*")]
    private static partial Regex LineMarkers { get; }
    [GeneratedRegex(@"^\s*(-{3,}|\*{3,}|_{3,}|\|?[\s:|-]+\|[\s:|-]*)\s*$")]  // rules, table separators
    private static partial Regex RuleOrTableSeparator { get; }
    [GeneratedRegex(@"!?\[([^\]]*)\]\([^)]*\)")]
    private static partial Regex LinkOrImage { get; }
    [GeneratedRegex(@"\*\*|__|~~|`")]
    private static partial Regex EmphasisMarks { get; }
    [GeneratedRegex(@"\*(\S|\S[^*]*\S)\*")]
    private static partial Regex Italic { get; }
    [GeneratedRegex(@"\s*\|\s*")]
    private static partial Regex TableBar { get; }
    [GeneratedRegex($$"""(?:@|📅\s?)(\d{4}-\d{2}-\d{2})(?:\{[a-z]+\})?(?![{{Word}}\-])""")]
    private static partial Regex PlainDate { get; }
}

/// A folder, like Apple Notes'. Deleting one is a tombstone (for sync); its notes go back to All Notes.
public sealed record Folder
{
    public string Id { get; init; } = Note.NewID();
    public required string Name { get; init; }
    public double UpdatedAt { get; init; } = Note.Now();
}

/// One dated line of a note, a task due that day or anything written for it; each day of a range carries its First and Last.
public sealed record DatedLine(string NoteID, int Line, string Day, string Text, bool IsTask, bool Done,
    string? First = null, string? Last = null, NoteColor? Color = null)
{
    public string Id => $"{NoteID}/{Line}/{Day}/{First}";
    public bool IsRange => First != null;

    /// The line with this event's colour set or removed: "{red}" after the date written first; other colours on its dates come off.
    public string Recolor(string line, NoteColor? color)
    {
        string[] days = [.. new[] { First, Last }.OfType<string>()];
        var token = new Regex($$"""((?:@|📅\s?)(?:{{string.Join("|", (days.Length == 0 ? [Day] : days).Select(Regex.Escape))}}))(?:\{[a-z]+\})?(?![{{Note.Word}}\-])""");
        var colored = false;
        return token.Replace(line, m =>
        {
            var replaced = m.Groups[1].Value + (colored || color is not { } c ? "" : "{" + c.RawValue + "}");
            colored = true;
            return replaced;
        });
    }

    /// Every day from `first` to `last`, both included.
    /// shortcut: stops after a year, so a typo like 2026→2062 can't fill decades; lift it if anyone plans longer.
    public static List<string> Days(string first, string last)
    {
        List<string> days = [];
        if (!TryParseDay(first, out var day)) return days;
        while (days.Count < 366 && day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) is var key && string.CompareOrdinal(key, last) <= 0)
        {
            days.Add(key);
            if (day == DateOnly.MaxValue) break;
            day = day.AddDays(1);
        }
        return days;
    }

    /// Dated lines by day. Ranges come first, earliest start first, so one keeps its row across its days.
    public static Dictionary<string, List<DatedLine>> ByDay(IEnumerable<DatedLine> lines) =>
        lines.GroupBy(line => line.Day).ToDictionary(day => day.Key, day => (List<DatedLine>)[
            .. day.Where(line => line.IsRange).OrderBy(line => line.First, StringComparer.Ordinal)
                .ThenByDescending(line => line.Last, StringComparer.Ordinal).ThenBy(line => line.NoteID, StringComparer.Ordinal).ThenBy(line => line.Line),
            .. day.Where(line => !line.IsRange)]);

    /// "2026-02-30" looks like a date but isn't one.
    public static bool IsDay(string day) => TryParseDay(day, out var parsed) && parsed.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) == day;

    // Like the Mac's formatter, it takes "2026-1-5" too; IsDay's round trip still asks for "2026-01-05".
    static bool TryParseDay(string day, out DateOnly parsed) =>
        DateOnly.TryParseExact(day, "yyyy-M-d", CultureInfo.InvariantCulture, DateTimeStyles.None, out parsed);
}

/// How dates in notes read: the text keeps "@2026-10-30" (the calendar, sync and Obsidian rely on it); previews show the region's pattern.
public static partial class DateStyle
{
    /// shortcut: always the region's; the Mac also lets Settings ▸ General choose one ("dateFormat"), add that with Windows' settings.
    public static string Pattern => Region;

    /// The region's numeric date with a 4-digit year, as the Mac's template "ddMMyyyy": "dd/MM/yyyy" (UK), "MM/dd/yyyy" (US).
    public static string Region => Field.Replace(CultureInfo.CurrentCulture.DateTimeFormat.ShortDatePattern,
        m => m.Value[0] switch { 'd' => "dd", 'M' => "MM", 'y' => "yyyy", _ => m.Value });

    /// "2026-10-30" in `pattern`; the same rule as the editor's formatDay. Names are English, like the app.
    public static string Format(string day, string? pattern = null, int? thisYear = null)
    {
        pattern ??= Pattern;
        var parts = day.Split('-', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 3 || !Number(parts[0], out var y) || !Number(parts[1], out var m) || !Number(parts[2], out var d) || m is < 1 or > 12) return day;
        // Swift's calendar rolls "February 30" over into March, as counting on from the 1st does.
        var weekday = y is >= 1 and <= 9999 ? (int)(((long)new DateTime((int)y, (int)m, 1).DayOfWeek + (d - 1) % 7 + 7) % 7) : 0;
        var names = CultureInfo.InvariantCulture.DateTimeFormat;
        var output = Field.Replace(pattern, match => match.Value[0] switch
        {
            'E' => match.Length > 3 ? names.DayNames[weekday] : names.AbbreviatedDayNames[weekday],
            'd' => match.Length > 1 ? parts[2] : d.ToString(CultureInfo.InvariantCulture),
            'M' => match.Length > 3 ? names.MonthNames[m - 1] : match.Length == 3 ? names.AbbreviatedMonthNames[m - 1]
                : match.Length == 2 ? parts[1] : m.ToString(CultureInfo.InvariantCulture),
            _ => parts[0],
        });
        return pattern.Contains('y') || y == (thisYear ?? DateTime.Now.Year) ? output : output + " " + y.ToString(CultureInfo.InvariantCulture);
    }

    // Swift's Int(String): an optional sign, then ASCII digits.
    static bool Number(string text, out long value) => long.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out value);

    [GeneratedRegex("E+|d+|M+|y+")]
    private static partial Regex Field { get; }
}

/// Apple Intelligence's title and tags for one version of a note.
public sealed record Suggestion(string NoteID, double UpdatedAt, string Title, IReadOnlyList<string> Tags);

/// A note as it was at the end of one local day (its last save that day). `Day` is "yyyy-MM-dd", local time.
public sealed record Snapshot(string Day, Note Note)
{
    public string Id => Note.Id + "/" + Day;
}

/// A note as the browser and the Mac's Codable spell it: newer fields optional, ids lowercased (a panel from before D76 may send capitals).
sealed class NoteJson : JsonConverter<Note>
{
    public override Note Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var json = JsonDocument.ParseValue(ref reader);
        var o = json.RootElement;
        return new Note
        {
            Id = Note.Lowercased(Required(o, "id").GetString()!),
            Kind = NoteKind.FromRawValue(Required(o, "kind").GetString()) ?? throw new JsonException("A note's kind is \"app\" or \"url\"."),
            Target = Required(o, "target").GetString()!,
            Label = Required(o, "label").GetString()!,
            Text = Optional(o, "text")?.GetString() ?? "",
            CreatedAt = Required(o, "createdAt").GetDouble(),
            UpdatedAt = Required(o, "updatedAt").GetDouble(),
            Pinned = Optional(o, "pinned")?.GetBoolean() ?? false,
            Starred = Optional(o, "starred")?.GetBoolean() ?? false,
            FolderID = Optional(o, "folderID") is { } folder ? Note.Lowercased(folder.GetString()!) : null,
            Color = Optional(o, "color") is { } color ? NoteColor.FromRawValue(color.GetString()) ?? throw new JsonException($"No colour label is called {color}.") : null,
            Locked = Optional(o, "locked")?.GetBoolean() ?? false,
        };
    }

    public override void Write(Utf8JsonWriter writer, Note note, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("id", note.Id);
        writer.WriteString("kind", note.Kind.RawValue);
        writer.WriteString("target", note.Target);
        writer.WriteString("label", note.Label);
        writer.WriteString("text", note.Text);
        writer.WriteNumber("createdAt", note.CreatedAt);
        writer.WriteNumber("updatedAt", note.UpdatedAt);
        writer.WriteBoolean("pinned", note.Pinned);
        writer.WriteBoolean("starred", note.Starred);
        if (note.FolderID is { } folder) writer.WriteString("folderID", folder);
        if (note.Color is { } color) writer.WriteString("color", color.RawValue);
        writer.WriteBoolean("locked", note.Locked);
        writer.WriteEndObject();
    }

    static JsonElement? Optional(JsonElement o, string key) => o.TryGetProperty(key, out var value) && value.ValueKind != JsonValueKind.Null ? value : null;
    static JsonElement Required(JsonElement o, string key) => Optional(o, key) ?? throw new JsonException($"A note needs its {key}.");
}
