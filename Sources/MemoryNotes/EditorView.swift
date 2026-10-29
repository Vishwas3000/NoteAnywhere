import SwiftUI
import WebKit

/// The shared Markdown editor (built from editor/, the same one the browser overlay uses) inside a WKWebView.
/// Falls back to a plain TextEditor if the editor files aren't in the app bundle.
struct NoteEditor: View {
    let noteID: String
    var toolbar = true
    var fontSize = 13
    var titleLine = false  // first line styled as the title, like Apple Notes
    var fit: ClosedRange<CGFloat>?  // grow with the content within this range instead of filling the space
    /// After ⌘-clicking a #tag or a date, which ask the main window to search for it or show its day.
    var showMainWindow: (() -> Void)?
    var focusIfEmpty = true  // a new note takes the cursor; off while something else (an address field) should have it
    @ObservedObject private var model = NotesModel.shared
    @ObservedObject private var lock = LockSession.shared
    @State private var contentHeight: CGFloat = 0
    @AppStorage(DateStyle.key) private var dateFormat = ""

    static let editorDir = Bundle.main.resourceURL?.appendingPathComponent("editor")

    var body: some View {
        if model.notes.first(where: { $0.id == noteID })?.locked == true, !lock.isUnlocked {
            LockedNoteView(compact: fit != nil)
        } else if let dir = Self.editorDir, FileManager.default.fileExists(atPath: dir.appendingPathComponent("mn-editor.js").path) {
            EditorWebView(dir: dir, markdown: model.textBinding(noteID),
                          options: ["toolbar": toolbar, "fontSize": fontSize, "titleLine": titleLine,
                                    "page": fit == nil, "datePattern": DateStyle.pattern], showMainWindow: showMainWindow,
                          focusIfEmpty: focusIfEmpty,
                          passesScroll: fit.map { contentHeight <= $0.upperBound } ?? false) { contentHeight = $0 }
                .id("\(noteID)/\(dateFormat)")  // a fresh editor per note keeps undo history per note; new date format redraws
                .frame(height: fit.map { min(max(contentHeight, $0.lowerBound), $0.upperBound) })
        } else {
            TextEditor(text: model.textBinding(noteID)).font(.body)
        }
    }
}

private struct EditorWebView: NSViewRepresentable {
    let dir: URL
    @Binding var markdown: String
    let options: [String: Any]
    let showMainWindow: (() -> Void)?
    let focusIfEmpty: Bool
    let passesScroll: Bool
    let onHeight: (CGFloat) -> Void

    /// A web view swallows scroll gestures even when it has nothing to scroll. An editor sized to its content
    /// (the overlay's cards, search results) passes them on, so the list around it scrolls.
    final class WebView: WKWebView {
        var passesScroll = false
        override func scrollWheel(with event: NSEvent) {
            if passesScroll { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "mn")
        config.writingToolsBehavior = .complete  // Apple Intelligence Writing Tools rewrite in place, like in Notes
        let web = WebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")  // transparent, so the panel/window material shows through
        web.navigationDelegate = context.coordinator
        web.loadFileURL(dir.appendingPathComponent("editor.html"), allowingReadAccessTo: dir)
        context.coordinator.web = web
        return web
    }

    func updateNSView(_ web: WebView, context: Context) {
        web.passesScroll = passesScroll
        context.coordinator.parent = self
        context.coordinator.push(markdown)  // e.g. the same note was edited in the browser
    }

    static func dismantleNSView(_ web: WebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "mn")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: EditorWebView
        weak var web: WKWebView?
        private var ready = false
        private var shown: String?  // the Markdown the editor currently holds

        init(_ parent: EditorWebView) { self.parent = parent }

        private func call(_ function: String, _ args: Any...) {
            guard let json = try? JSONSerialization.data(withJSONObject: args, options: .fragmentsAllowed),
                  let list = String(data: json, encoding: .utf8) else { return }
            web?.evaluateJavaScript("MNHost.\(function)(...\(list))")
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
                if parent.markdown.isEmpty && parent.focusIfEmpty {  // a new note: start typing right away
                    web?.window?.makeFirstResponder(web)
                    call("focus")
                }
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
            case "height":
                if let value = body["value"] as? Double { parent.onHeight(value) }
            case "tag":
                guard let tag = body["tag"] as? String else { return }
                NotesModel.shared.searchRequest = "#" + tag
                parent.showMainWindow?()
            case "date":
                guard let day = body["day"] as? String else { return }
                NotesModel.shared.calendarRequest = day
                parent.showMainWindow?()
            case "openNote":
                if let id = body["id"] as? String { NotesModel.shared.openRequest = id }
            default:
                break
            }
        }

        // Links open in the default browser, never inside the editor.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }
    }
}
