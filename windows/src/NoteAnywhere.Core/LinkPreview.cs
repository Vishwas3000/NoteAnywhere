using System.Globalization;
using System.Text.RegularExpressions;

namespace NoteAnywhere.Core;

/// Notion-style previews of a pasted link (a mention or a card): what a page's <head> describes, as the Mac's
/// LinkPreview.parse reads it: Open Graph, then Twitter cards, then plain HTML.
public static partial class LinkPreview
{
    /// From Parse, Icon and Image are the pictures' addresses; once fetched they become noteimage:<id> sources ("" for none).
    public sealed record Page(string Title, string Description, string Icon, string Image);

    static readonly Dictionary<string, string> Entities = new()
    {
        ["amp"] = "&", ["quot"] = "\"", ["apos"] = "'", ["lt"] = "<", ["gt"] = ">", ["nbsp"] = " ", ["ndash"] = "–",
        ["mdash"] = "—", ["hellip"] = "…", ["lsquo"] = "‘", ["rsquo"] = "’", ["ldquo"] = "“", ["rdquo"] = "”",
    };

    public static Page Parse(string html, Uri page)
    {
        var end = html.IndexOf("</head>", StringComparison.OrdinalIgnoreCase);
        var head = end >= 0 ? html[..end] : html;
        var metas = new Dictionary<string, string>();
        var icons = new List<(string Href, bool Apple, int Size)>();
        var baseUri = page;
        foreach (Match tag in Tag().Matches(head))
        {
            var attrs = new Dictionary<string, string>();
            foreach (Match a in Attribute().Matches(tag.Groups[2].Value))
                attrs[a.Groups[1].Value.ToLowerInvariant()] = Text(a.Groups[2].Success ? a.Groups[2].Value : a.Groups[3].Success ? a.Groups[3].Value : a.Groups[4].Value);
            switch (tag.Groups[1].Value.ToLowerInvariant())
            {
                case "meta":
                    var key = (attrs.GetValueOrDefault("property") ?? attrs.GetValueOrDefault("name"))?.ToLowerInvariant();
                    if (key != null && attrs.GetValueOrDefault("content") is { Length: > 0 } value) metas.TryAdd(key, value);
                    break;
                case "link":
                    var rel = (attrs.GetValueOrDefault("rel") ?? "").ToLowerInvariant().Split(' ', StringSplitOptions.RemoveEmptyEntries);
                    var href = attrs.GetValueOrDefault("href") ?? "";
                    var apple = rel.Any(r => r.StartsWith("apple-touch-icon", StringComparison.Ordinal));
                    // SVG icons can't be kept as note images; the next best (or /favicon.ico) stands in.
                    if (!(apple || rel.Contains("icon")) || href.Length == 0 || attrs.GetValueOrDefault("type")?.Contains("svg") == true
                        || href.ToLowerInvariant().Split('?')[0].EndsWith(".svg", StringComparison.Ordinal)) continue;
                    var size = new string((attrs.GetValueOrDefault("sizes") ?? "").TakeWhile(char.IsAsciiDigit).ToArray());
                    icons.Add((href, apple, int.TryParse(size, out var n) ? n : 0));
                    break;
                default:
                    if (attrs.GetValueOrDefault("href") is { } b && Uri.TryCreate(page, b, out var resolved)) baseUri = resolved;
                    break;
            }
        }
        string? First(params string[] keys) => keys.Select(k => metas.GetValueOrDefault(k)).FirstOrDefault(v => v != null);
        string Resolve(string? href) => !string.IsNullOrEmpty(href) && Uri.TryCreate(baseUri, href, out var u) ? u.AbsoluteUri : "";
        var title = First("og:title", "twitter:title") ?? (TitleTag().Match(head) is { Success: true } t ? Text(t.Groups[1].Value) : null);
        var description = First("og:description", "twitter:description", "description") ?? "";
        if (new StringInfo(description).LengthInTextElements > 300)
            description = new StringInfo(description).SubstringByTextElements(0, 299).TrimEnd() + "…";
        // The largest icon, apple-touch icons first; Swift's max keeps the first of equals, as MaxBy does.
        var icon = icons.Count == 0 ? null : Resolve(icons.MaxBy(i => (i.Apple ? 1 : 0, i.Size)).Href);
        return new Page(
            string.IsNullOrEmpty(title) ? (page.Host.Length > 0 ? page.Host : page.AbsoluteUri) : title,
            description,
            icon ?? new Uri(page, "/favicon.ico").AbsoluteUri,
            Resolve(First("og:image", "og:image:secure_url", "twitter:image", "twitter:image:src")));
    }

    /// HTML text as plain text: entities decoded, whitespace collapsed.
    static string Text(string html) =>
        Whitespace().Replace(Entity().Replace(html, m =>
        {
            if (m.Groups[2].Success)
                return int.TryParse(m.Groups[2].Value, m.Groups[1].Success ? NumberStyles.HexNumber : NumberStyles.None, CultureInfo.InvariantCulture, out var code)
                       && code is > 0 and <= 0x10FFFF and not (>= 0xD800 and <= 0xDFFF)
                    ? char.ConvertFromUtf32(code) : m.Value;
            return Entities.GetValueOrDefault(m.Groups[3].Value.ToLowerInvariant()) ?? m.Value;
        }), " ").Trim();

    [GeneratedRegex("""<(meta|link|base)\b((?:[^>"']|"[^"]*"|'[^']*')*)>""", RegexOptions.IgnoreCase)] private static partial Regex Tag();
    [GeneratedRegex("""([^\s=/>]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))""")] private static partial Regex Attribute();
    [GeneratedRegex(@"<title\b[^>]*>(.*?)</title>", RegexOptions.IgnoreCase | RegexOptions.Singleline)] private static partial Regex TitleTag();
    [GeneratedRegex(@"&(?:#([xX])?([0-9a-fA-F]+)|([a-zA-Z]+));")] private static partial Regex Entity();
    [GeneratedRegex(@"\s+")] private static partial Regex Whitespace();
}
