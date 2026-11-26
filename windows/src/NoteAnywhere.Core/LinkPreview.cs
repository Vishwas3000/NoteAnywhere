using System.Globalization;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Text.Unicode;

namespace NoteAnywhere.Core;

/// Notion-style previews of a pasted link (a mention or a card): what a page's <head> describes, as the Mac's
/// LinkPreview.parse reads it: Open Graph, then Twitter cards, then plain HTML.
public static partial class LinkPreview
{
    /// From Parse, Icon and Image are the pictures' addresses; once fetched they become noteimage:<id> sources ("" for none).
    public sealed record Page(string Title, string Description, string Icon, string Image);

    const int PageLimit = 2 << 20, PictureLimit = 5 << 20;

    /// For previews in the app and the browser host. As URLSession: decompressing, and naming itself, which some sites
    /// want before they answer.
    public static readonly HttpClient Web = new(new SocketsHttpHandler { AutomaticDecompression = DecompressionMethods.All })
        { DefaultRequestHeaders = { { "User-Agent", "NoteAnywhere" } } };

    /// The page's preview with its pictures kept as note images, as the Mac's LinkPreview.fetch; throws with a message to
    /// show. `toPng` makes an ICO or BMP the PNG of its largest frame (the app's decodes with WPF); without it they're left out.
    public static async Task<Page> FetchAsync(Uri url, HttpClient http, Func<byte[], byte[]>? toPng)
    {
        if (!url.IsAbsoluteUri || url.Scheme is not ("http" or "https") || url.Host.Length == 0)
            throw new InvalidOperationException("Only web addresses (http or https) have previews.");
        var (data, final) = await DownloadAsync(http, url, PageLimit).ConfigureAwait(false);
        var page = Parse(Decode(data.AsSpan(0, Math.Min(data.Length, PageLimit))), final);
        var (icon, image) = (SavePictureAsync(page.Icon, http, toPng), SavePictureAsync(page.Image, http, toPng));
        return page with { Icon = await icon.ConfigureAwait(false), Image = await image.ConfigureAwait(false) };
    }

    /// A cut at 2 MB can split a UTF-8 character, so try without the last few bytes before falling back to Latin-1.
    static string Decode(ReadOnlySpan<byte> html)
    {
        for (var drop = 0; drop <= Math.Min(3, html.Length); drop++)
            if (Utf8.IsValid(html[..^drop])) return Encoding.UTF8.GetString(html[..^drop]);
        return Encoding.Latin1.GetString(html);
    }

    /// Downloads a picture and keeps it as a note image: its noteimage:<id> source, or "" when there's none or it fails
    /// (the preview still works).
    internal static async Task<string> SavePictureAsync(string address, HttpClient http, Func<byte[], byte[]>? toPng)
    {
        // Never file: or other schemes: a page shouldn't be able to copy a local file into the notes.
        if (!Uri.TryCreate(address, UriKind.Absolute, out var url) || url.Scheme is not ("http" or "https" or "data")) return "";
        try
        {
            var data = url.Scheme == "data" ? DataUrl(address) : (await DownloadAsync(http, url, PictureLimit).ConfigureAwait(false)).Data;
            if (data.Length > PictureLimit) throw new InvalidOperationException("Pictures can be up to 5 MB.");
            var (bytes, type) = Picture(data, toPng);
            return NoteStore.ImageScheme + ":" + NoteStore.SaveImage(bytes, type);
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"Link preview: no picture from {address}: {e.Message}");
            return "";
        }
    }

    // shortcut: base64 only, as pictures are written; a percent-encoded one would need decoding byte by byte.
    static byte[] DataUrl(string address) =>
        address.IndexOf(',') is var comma and > 0 && address[..comma].EndsWith(";base64", StringComparison.OrdinalIgnoreCase)
            ? Convert.FromBase64String(Uri.UnescapeDataString(address[(comma + 1)..]))
            : throw new InvalidOperationException("Only base64 data URLs hold pictures here.");

    /// The bytes as a type notes hold, judged by content (favicons are often mislabeled): kept when they already are one;
    /// an ICO or BMP becomes a PNG through `toPng`.
    internal static (byte[] Data, string Type) Picture(byte[] data, Func<byte[], byte[]>? toPng)
    {
        if (TypeOf(data) is { } type) return (data, type);
        if (toPng != null && (data.AsSpan().StartsWith((ReadOnlySpan<byte>)[0, 0, 1, 0]) || data.AsSpan().StartsWith("BM"u8)))
            return (toPng(data), "image/png");
        throw new InvalidOperationException("Not a picture (or an SVG).");
    }

    /// Which of NoteStore.ImageTypes the bytes are, by their signature: ImageIO's judgement on the Mac.
    static string? TypeOf(ReadOnlySpan<byte> data) =>
        data.StartsWith((ReadOnlySpan<byte>)[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) ? "image/png"
        : data.StartsWith((ReadOnlySpan<byte>)[0xFF, 0xD8, 0xFF]) ? "image/jpeg"
        : data.StartsWith("GIF87a"u8) || data.StartsWith("GIF89a"u8) ? "image/gif"
        : data.Length >= 12 && data.StartsWith("RIFF"u8) && data[8..12].SequenceEqual("WEBP"u8) ? "image/webp"
        : data.Length >= 12 && data[4..8].SequenceEqual("ftyp"u8) ? Encoding.ASCII.GetString(data[8..12]) switch  // HEIF's major brand
        {
            "avif" or "avis" => "image/avif",
            "heic" or "heix" or "heim" or "heis" => "image/heic",
            "mif1" or "msf1" => "image/heif",
            _ => null,
        }
        : null;

    /// Up to `limit` + 1 bytes, so the caller can tell a cut file; follows redirects and returns the final address.
    static async Task<(byte[] Data, Uri Final)> DownloadAsync(HttpClient http, Uri url, int limit)
    {
        using var idle = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        try
        {
            using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, idle.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"{url.Host} answered {(int)response.StatusCode}.");
            await using var body = await response.Content.ReadAsStreamAsync(idle.Token).ConfigureAwait(false);
            var data = new MemoryStream();
            var buffer = new byte[81920];
            while (data.Length <= limit)
            {
                idle.CancelAfter(TimeSpan.FromSeconds(10));  // as the Mac's timeoutInterval: 10 s without a byte, not 10 s in all
                var read = await body.ReadAsync(buffer, idle.Token).ConfigureAwait(false);
                if (read == 0) break;
                data.Write(buffer, 0, read);
            }
            return (data.ToArray(), response.RequestMessage?.RequestUri ?? url);
        }
        catch (OperationCanceledException) when (idle.IsCancellationRequested)
        {
            throw new TimeoutException("The request timed out.");
        }
    }

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
