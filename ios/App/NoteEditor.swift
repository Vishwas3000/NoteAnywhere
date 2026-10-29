import SwiftUI
import WebKit

/// The shared Markdown editor (editor/ + app/editor.html, the same one the Mac app and the browser use) in a WKWebView.
/// Falls back to a plain TextEditor if the editor files aren't in the bundle.
struct NoteEditor: View {
    let noteID: String
    var openNote: (String) -> Void = { _ in }
    @ObservedObject private var model = NotesModel.shared
    @AppStorage(DateStyle.key) private var dateFormat = ""

    static let editorDir = Bundle.main.resourceURL?.appendingPathComponent("editor")

    var body: some View {
        if let dir = Self.editorDir, FileManager.default.fileExists(atPath: dir.appendingPathComponent("mn-editor.js").path) {
            // Body text follows Dynamic Type, starting from the iPhone's 17 pt.
            let fontSize = Int(UIFontMetrics(forTextStyle: .body).scaledValue(for: 17).rounded())
            EditorWebView(dir: dir, markdown: model.binding(noteID, \.text),
                          options: ["toolbar": true, "fontSize": fontSize, "titleLine": true, "datePattern": DateStyle.pattern],
                          openNote: openNote)
                .id("\(noteID)/\(dateFormat)")  // a fresh editor per note keeps undo history per note; new date format redraws
        } else {
            TextEditor(text: model.binding(noteID, \.text)).font(.body).padding(.horizontal)
        }
    }
}

private struct EditorWebView: UIViewRepresentable {
    let dir: URL
    @Binding var markdown: String
    let options: [String: Any]
    let openNote: (String) -> Void

    /// iPhone-only styling on top of the shared page: side margins, no text inflation on rotation, one scrolling row
    /// of finger-sized toolbar buttons, a ✨ button that's always visible and no block-drag gutter (both are hover UI), and no ✨ menu before
    /// iOS 26 (Apple Intelligence's on-device model needs it).
    private static var css: String {
        var css = """
            body { padding: 0 20px 48px; -webkit-text-size-adjust: 100%; }
            .mn-toolbar { flex-wrap: nowrap; overflow-x: auto; scrollbar-width: none;
                -webkit-mask-image: linear-gradient(to right, #000 calc(100% - 28px), transparent); }
            .mn-toolbar button { min-width: 36px; height: 36px; flex: none; }
            .mn-editor:has(.mn-ai) .mn-toolbar { padding-right: 0; margin-right: 44px; }
            .mn-ai > button { width: 36px; height: 36px; opacity: 1; }
            .mn-content { padding-left: 0; } .mn-drag { display: none; } .mn-content .mn-date { white-space: nowrap; }
            """
        if #unavailable(iOS 26) { css += " .mn-ai { display: none; } .mn-editor:has(.mn-ai) .mn-toolbar { margin-right: 0; }" }
        return css
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "mn")
        config.setURLSchemeHandler(ImageScheme(), forURLScheme: NoteStore.imageScheme)
        let style = "document.head.append(Object.assign(document.createElement('style'), { textContent: \(Self.quoted(Self.css)) }))"
        config.userContentController.addUserScript(WKUserScript(source: style, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.writingToolsBehavior = .complete  // Apple Intelligence Writing Tools rewrite in place, like in Notes
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.keyboardDismissMode = .interactive
        web.navigationDelegate = context.coordinator
        web.loadFileURL(dir.appendingPathComponent("editor.html"), allowingReadAccessTo: dir)
        context.coordinator.web = web
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.push(markdown)  // e.g. the same note arrived from the Mac by sync
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "mn")
    }

    static func quoted(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: EditorWebView
        weak var web: WKWebView?
        private var ready = false
        private var shown: String?  // the Markdown the editor currently holds

        init(_ parent: EditorWebView) { self.parent = parent }

        private func call(_ function: String, _ args: Any...) {
            web?.evaluateJavaScript("MNHost.\(function)(...\(EditorWebView.quoted(args)))")
        }

        func push(_ markdown: String) {
            guard ready, markdown != shown else { return }
            shown = markdown
            call("set", markdown)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                shown = parent.markdown
                call("load", parent.markdown, parent.options)
                if parent.markdown.isEmpty { call("focus") }  // a new note: the cursor is ready (the keyboard waits for a tap)
                // The shared ✨ menu says "on this Mac".
                let footer = "Apple Intelligence · on this \(UIDevice.current.model)"
                web?.evaluateJavaScript("document.querySelectorAll('.mn-ai-footer').forEach(e => e.textContent = \(EditorWebView.quoted(footer)))")
            case "change":
                guard let markdown = body["markdown"] as? String else { return }
                shown = markdown
                parent.markdown = markdown
            case "ai":
                guard let id = body["id"] as? Int, let text = body["text"] as? String else { return }
                let action = (body["action"] as? String).flatMap(Assistant.Action.init(rawValue:))
                Task { @MainActor in
                    do {
                        guard let action else { throw Assistant.Failure(errorDescription: "Unknown action.") }
                        call("aiDone", id, try await Assistant.run(action, on: text), NSNull())
                    } catch {
                        call("aiDone", id, NSNull(), error.localizedDescription)
                    }
                }
            case "addImage":
                guard let id = body["id"] as? Int else { return }
                do {
                    guard let data = (body["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                        throw NoteStore.ImageError(errorDescription: "The image data was unreadable.")
                    }
                    call("reply", id, NoteStore.imageScheme + ":" + (try NoteStore.saveImage(data, type: body["mime"] as? String ?? "")), NSNull())
                } catch {
                    call("reply", id, NSNull(), error.localizedDescription)
                }
            case "date":  // ⌘-click, so only with a hardware keyboard on the phone
                if let day = body["day"] as? String { NotesModel.shared.calendarRequest = day }
            case "tag":
                if let tag = body["tag"] as? String { NotesModel.shared.searchRequest = "#" + tag }
            case "openNote":
                if let id = body["id"] as? String { parent.openNote(id) }
            default:
                break
            }
        }

        // Links open in Safari (or their app), never inside the editor.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                UIApplication.shared.open(url)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }
    }
}
