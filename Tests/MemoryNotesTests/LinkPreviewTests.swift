import Foundation
import ImageIO
import Testing
@testable import MemoryNotes

/// Link previews (mentions and cards): what a page's HTML yields, and how its pictures are kept. No network.
@Suite(.serialized) struct LinkPreviewTests {
    init() throws {
        _ = SyncStoreTests.dir
        try #require(NoteStore.root.path == SyncStoreTests.dir, "would touch the real notes database")
    }

    @Test func openGraphWins() {
        // Attributes in any order and either quote, entities, relative and protocol-relative addresses.
        let html = """
            <!doctype html><html><head>
            <meta charset="utf-8"><title>Ignored &ndash; title</title>
            <meta content='Quick Start &#x2013; React' property='og:title'>
            <meta name="twitter:title" content="Not this">
            <meta name="description" content="Plain description">
            <meta property="og:description" content="Welcome to the &quot;React&quot; docs!
                This page &amp; the next&#39;s &lt;b&gt;&nbsp;intro." />
            <meta property="og:image" content="/images/og-learn.png?a=1&amp;b=2">
            <link rel="icon" href="/favicon-32x32.png" sizes="32x32" type="image/png">
            <link href="//cdn.react.dev/apple-touch-icon.png" rel="apple-touch-icon" sizes="180x180">
            <link rel="icon" href="/favicon.svg" type="image/svg+xml">
            </head><body><title>An SVG's title</title></body></html>
            """
        let page = LinkPreview.parse(html: html, base: URL(string: "https://react.dev/learn")!)
        #expect(page == LinkPreview.Page(
            title: "Quick Start – React",
            description: "Welcome to the \"React\" docs! This page & the next's <b> intro.",
            icon: "https://cdn.react.dev/apple-touch-icon.png",
            image: "https://react.dev/images/og-learn.png?a=1&b=2"))
    }

    @Test func plainHTML() {
        // No Open Graph: <title>, the description meta, the largest icon, resolved against <base href>.
        let html = """
            <HTML><HEAD><BASE HREF="https://static.example.com/site/">
            <TITLE>
              Bengaluru  &mdash;
              Wikipedia
            </TITLE>
            <META NAME="Description" CONTENT="Capital of Karnataka">
            <LINK REL="shortcut icon" HREF="small.ico" SIZES="16x16">
            <LINK REL="icon" HREF="big.png" SIZES="64x64">
            <LINK REL="mask-icon" HREF="mask.png">
            </HEAD><BODY>…</BODY></HTML>
            """
        let page = LinkPreview.parse(html: html, base: URL(string: "https://en.example.org/wiki/Bengaluru")!)
        #expect(page == LinkPreview.Page(title: "Bengaluru — Wikipedia", description: "Capital of Karnataka",
                                         icon: "https://static.example.com/site/big.png", image: ""))
    }

    @Test func nothingButTheHost() {
        // Only an SVG icon (not kept), so the site's /favicon.ico stands in; the title is the host.
        let html = #"<html><head><link rel="icon" href="/icon.svg?v=2"></head><body><p>Hi</p></body></html>"#
        let page = LinkPreview.parse(html: html, base: URL(string: "https://react.dev/learn/thinking?x=1")!)
        #expect(page == LinkPreview.Page(title: "react.dev", description: "", icon: "https://react.dev/favicon.ico", image: ""))
        #expect(LinkPreview.parse(html: "<title> </title>", base: URL(string: "http://localhost:3000/")!).title == "localhost")
    }

    @Test func longDescriptionIsTrimmed() {
        let html = "<meta name=description content=\"\(String(repeating: "word ", count: 100))\">"
        let description = LinkPreview.parse(html: html, base: URL(string: "https://a.com")!).description
        #expect(description.count <= 300 && description.hasSuffix("…") && description.hasPrefix("word word"))
    }

    @Test func picturesBecomeTypesNotesHold() throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAEUlEQVR42mP4z8DwHwyB+AMAYMQK9v1ByAoAAAAASUVORK5CYII="))
        let kept = try LinkPreview.picture(png)
        #expect(kept.data == png && kept.type == "image/png")
        // A favicon.ico with two sizes: kept as a PNG of the larger.
        let converted = try LinkPreview.picture(Self.ico([16, 32]))
        #expect(converted.type == "image/png")
        let source = try #require(CGImageSourceCreateWithData(converted.data as CFData, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 32)
        #expect(throws: LinkPreview.Failure.self) { try LinkPreview.picture(Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)) }
        #expect(throws: LinkPreview.Failure.self) { try LinkPreview.picture(Data("<html>Not found</html>".utf8)) }
    }

    @Test func savesPictureAsNoteImage() async throws {
        let src = await LinkPreview.savePicture("data:image/x-icon;base64," + Self.ico([16]).base64EncodedString())
        let id = try #require(src.split(separator: ":", maxSplits: 1).last.map(String.init))
        #expect(src.hasPrefix("noteimage:") && NoteStore.image(id)?.type == "image/png")
        #expect(await LinkPreview.savePicture("") == "")
        #expect(await LinkPreview.savePicture("file:///etc/hosts") == "")  // a page can't pull in local files
    }

    @Test func cardNoteTitle() {
        let note = Note(kind: .app, target: "x", label: "X", text: """
            > [!bookmark] [Quick Start – React](https://react.dev/learn)
            > Welcome to the React docs!
            > ![](noteimage:abc "icon") ![](noteimage:def)

            Read [React](https://react.dev "mention noteimage:abc") today
            """)
        #expect(note.title == "Quick Start – React")
        #expect(note.preview == "Welcome to the React docs! Read React today")
    }

    /// A Windows icon of 32-bit BMP frames, one per size, each a solid colour.
    static func ico(_ sizes: [Int]) -> Data {
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let frames = sizes.map { n -> Data in
            le(UInt32(40)) + le(Int32(n)) + le(Int32(n * 2)) + le(UInt16(1)) + le(UInt16(32)) + Data(count: 24)
                + Data(Array(repeating: [0x20, 0x80, 0xE0, 0xFF] as [UInt8], count: n * n).joined())
                + Data(count: (n + 31) / 32 * 4 * n)  // AND mask: all opaque
        }
        var offset = 6 + 16 * sizes.count, out = le(UInt16(0)) + le(UInt16(1)) + le(UInt16(sizes.count))
        for (n, frame) in zip(sizes, frames) {
            out += Data([UInt8(n), UInt8(n), 0, 0]) + le(UInt16(1)) + le(UInt16(32)) + le(UInt32(frame.count)) + le(UInt32(offset))
            offset += frame.count
        }
        return frames.reduce(out, +)
    }
}
