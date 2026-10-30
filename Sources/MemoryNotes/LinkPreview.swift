import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Notion-style previews of a pasted link (a mention or a card): the page's title, description, icon and picture,
/// the pictures kept as note images so the note shows them offline and on every device.
enum LinkPreview {
    struct Failure: LocalizedError { let errorDescription: String? }

    /// From `parse`, icon and image are the pictures' addresses; from `fetch`, their noteimage:<id> sources ("" for none).
    struct Page: Encodable, Equatable {
        var title: String, description: String, icon: String, image: String
    }

    static func fetch(_ url: URL) async throws -> Page {
        guard ["http", "https"].contains(url.scheme?.lowercased()), url.host?.isEmpty == false else {
            throw Failure(errorDescription: "Only web addresses (http or https) have previews.")
        }
        let (data, final) = try await download(url, upTo: 2 << 20)
        let html = data.prefix(2 << 20)
        // A cut at 2 MB can split a UTF-8 character, so try without the last few bytes before falling back.
        let text = (0...3).lazy.compactMap { String(data: html.dropLast($0), encoding: .utf8) }.first
            ?? String(data: html, encoding: .isoLatin1) ?? ""
        var page = parse(html: text, base: final)
        let (iconURL, imageURL) = (page.icon, page.image)
        async let icon = savePicture(iconURL), image = savePicture(imageURL)
        (page.icon, page.image) = await (icon, image)
        return page
    }

    private static let entities = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " ",
                                   "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”"]

    /// The preview a page's <head> describes: Open Graph, then Twitter cards, then plain HTML.
    static func parse(html: String, base page: URL) -> Page {
        let head = html.range(of: "</head>", options: .caseInsensitive).map { html[..<$0.lowerBound] } ?? html[...]
        var metas: [String: String] = [:], icons: [(href: String, apple: Bool, size: Int)] = [], base = page
        for tag in head.matches(of: #/<(meta|link|base)\b((?:[^>"']|"[^"]*"|'[^']*')*)>/#.ignoresCase()) {
            var attrs: [String: String] = [:]
            for attr in tag.2.matches(of: #/([^\s=/>]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/#) {
                attrs[attr.1.lowercased()] = text(attr.2 ?? attr.3 ?? attr.4 ?? "")
            }
            switch tag.1.lowercased() {
            case "meta":
                if let key = (attrs["property"] ?? attrs["name"])?.lowercased(), let value = attrs["content"], !value.isEmpty,
                   metas[key] == nil { metas[key] = value }
            case "link":
                let rel = (attrs["rel"] ?? "").lowercased().split(separator: " "), href = attrs["href"] ?? ""
                let apple = rel.contains { $0.hasPrefix("apple-touch-icon") }
                // SVG icons can't be kept as note images; the next best (or /favicon.ico) stands in.
                guard apple || rel.contains("icon"), !href.isEmpty, attrs["type"]?.contains("svg") != true,
                      !href.lowercased().split(separator: "?")[0].hasSuffix(".svg") else { continue }
                icons.append((href, apple, Int(attrs["sizes"]?.prefix { $0.isNumber } ?? "") ?? 0))
            default:
                if let href = attrs["href"], let url = URL(string: href, relativeTo: page) { base = url.absoluteURL }
            }
        }
        func first(_ keys: String...) -> String? { keys.lazy.compactMap { metas[$0] }.first }
        func resolve(_ href: String?) -> String {
            guard let href, !href.isEmpty else { return "" }
            return URL(string: href, relativeTo: base)?.absoluteURL.absoluteString ?? ""
        }
        let title = first("og:title", "twitter:title")
            ?? head.firstMatch(of: #/<title\b[^>]*>(.*?)<\/title>/#.ignoresCase().dotMatchesNewlines()).map { text($0.1) }
        var description = first("og:description", "twitter:description", "description") ?? ""
        if description.count > 300 { description = description.prefix(299).trimmingCharacters(in: .whitespaces) + "…" }
        let icon = icons.max { ($0.apple ? 1 : 0, $0.size) < ($1.apple ? 1 : 0, $1.size) }.map { resolve($0.href) }
        return Page(title: title.flatMap { $0.isEmpty ? nil : $0 } ?? page.host ?? page.absoluteString, description: description,
                    icon: icon ?? URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL.absoluteString ?? "",
                    image: resolve(first("og:image", "og:image:secure_url", "twitter:image", "twitter:image:src")))
    }

    /// HTML text as plain text: entities decoded, whitespace collapsed.
    private static func text(_ html: Substring) -> String {
        html.replacing(#/&(?:#([xX])?([0-9a-fA-F]+)|([a-zA-Z]+));/#) { m in
            if let digits = m.2 {
                return Int(digits, radix: m.1 == nil ? 10 : 16).flatMap { UInt32(exactly: $0) }.flatMap(Unicode.Scalar.init)
                    .map { String(Character($0)) } ?? String(m.0)
            }
            return entities[m.3.map { $0.lowercased() } ?? ""] ?? String(m.0)
        }
        .replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Downloads a picture and keeps it as a note image; "" when there is none or it fails (the preview still works).
    static func savePicture(_ address: String) async -> String {
        // Never file: or other schemes: a page shouldn't be able to copy a local file into the notes.
        guard let url = URL(string: address), ["http", "https", "data"].contains(url.scheme?.lowercased()) else { return "" }
        do {
            let (data, _) = try await download(url, upTo: 5 << 20)
            guard data.count <= 5 << 20 else { throw Failure(errorDescription: "Pictures can be up to 5 MB.") }
            let picture = try picture(data)
            return NoteStore.imageScheme + ":" + (try NoteStore.saveImage(picture.data, type: picture.type))
        } catch {
            NSLog("Link preview: no picture from %@: %@", address, error.localizedDescription)
            return ""
        }
    }

    /// The bytes as a type notes can hold, judged by content (favicons are often mislabeled): kept as they are when
    /// they already are one, otherwise (ICO, BMP, …) the largest frame as PNG.
    static func picture(_ data: Data) throws -> (data: Data, type: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let uti = CGImageSourceGetType(source),
              CGImageSourceGetCount(source) > 0 else { throw Failure(errorDescription: "Not a picture (or an SVG).") }
        if let type = UTType(uti as String)?.preferredMIMEType, NoteStore.imageTypes.contains(type) { return (data, type) }
        let frames = (0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
        let png = NSMutableData()
        guard let frame = frames.max(by: { $0.width < $1.width }),
              let out = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(errorDescription: "The picture couldn't be read.")
        }
        CGImageDestinationAddImage(out, frame, nil)
        guard CGImageDestinationFinalize(out) else { throw Failure(errorDescription: "The picture couldn't be converted.") }
        return (png as Data, "image/png")
    }

    /// Up to `limit` + 1 bytes, so the caller can tell a cut file; follows redirects and returns the final address.
    private static func download(_ url: URL, upTo limit: Int) async throws -> (Data, URL) {
        let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: url, timeoutInterval: 10))
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw Failure(errorDescription: "\(url.host ?? "The site") answered \(status).")
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { break }
        }
        return (data, response.url ?? url)
    }
}
