import Foundation
import Testing
import WebKit
@testable import MemoryNotes

/// The Mac editor shows a saved image (D53): the real editor page, ImageScheme and NoteStore, on a scratch store.
@Suite(.serialized) struct ImageSchemeTests {
    init() throws {
        _ = SyncStoreTests.dir
        try #require(NoteStore.root.path == SyncStoreTests.dir, "would touch the real notes database")
    }

    final class Bridge: NSObject, WKScriptMessageHandler {
        var ready = false
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            if (m.body as? [String: Any])?["type"] as? String == "ready" { ready = true }
        }
    }

    @MainActor @Test func editorShowsSavedImage() async throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAEUlEQVR42mP4z8DwHwyB+AMAYMQK9v1ByAoAAAAASUVORK5CYII="))
        let id = try NoteStore.saveImage(png, type: "image/png")
        // The page as scripts/install.sh lays it out: editor/dist next to app/editor.html.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(atPath: repo.appendingPathComponent("editor/dist").path) {
            try FileManager.default.copyItem(at: repo.appendingPathComponent("editor/dist/\(file)"), to: dir.appendingPathComponent(file))
        }
        try FileManager.default.copyItem(at: repo.appendingPathComponent("app/editor.html"), to: dir.appendingPathComponent("editor.html"))

        let config = WKWebViewConfiguration(), bridge = Bridge()
        config.userContentController.add(bridge, name: "mn")
        config.setURLSchemeHandler(ImageScheme(), forURLScheme: NoteStore.imageScheme)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        web.loadFileURL(dir.appendingPathComponent("editor.html"), allowingReadAccessTo: dir)
        for _ in 0..<50 where !bridge.ready { try await Task.sleep(for: .milliseconds(100)) }
        try #require(bridge.ready)
        _ = try await web.evaluateJavaScript("MNHost.load('Text\\n\\n![](noteimage:\(id))', {}), 0")
        var shown: String?
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            shown = try await web.evaluateJavaScript("(i => i ? i.naturalWidth + ' ' + i.alt : 'none')(document.querySelector('img'))") as? String
            if shown != "0 " { break }
        }
        #expect(shown == "2 ")
    }
}
