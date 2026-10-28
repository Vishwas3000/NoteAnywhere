import SwiftUI
import UniformTypeIdentifiers

/// "NoteAnywhere" in the share sheet: a shared page becomes a website note for that page (same target as the
/// browser extension makes), shared text becomes the note's body. Saved straight into the App Group database;
/// the app picks it up (and syncs it) the next time it's active.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let draft = ShareDraft()
        let host = UIHostingController(rootView: ShareView(draft: draft) { [weak self] saved in
            if saved { self?.extensionContext?.completeRequest(returningItems: nil) }
            else { self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled)) }
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        Task { await draft.load(items) }
    }
}

@MainActor
final class ShareDraft: ObservableObject {
    @Published var text = ""
    @Published var title = ""
    @Published var target = ""
    @Published var loading = true
    @Published var error: String?

    func load(_ items: [NSExtensionItem]) async {
        defer { loading = false }
        let plist = UTType.propertyList.identifier, url = UTType.url.identifier, plain = UTType.plainText.identifier
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(plist),
                   let results = try? await provider.loadItem(forTypeIdentifier: plist) as? [String: Any],
                   let page = results[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] {
                    // Safari ran GetPage.js: the page's own address and title.
                    if let address = (page["url"] as? String).flatMap(URL.init(string:)) { target = Note.pageTarget(address) }
                    title = page["title"] as? String ?? title
                } else if provider.hasItemConformingToTypeIdentifier(url),
                          let link = try? await provider.loadItem(forTypeIdentifier: url) as? URL {
                    let page = Note.pageTarget(link)
                    if page.isEmpty { text += (text.isEmpty ? "" : "\n") + link.absoluteString } else if target.isEmpty { target = page }
                } else if provider.hasItemConformingToTypeIdentifier(plain),
                          let shared = try? await provider.loadItem(forTypeIdentifier: plain) as? String {
                    text += (text.isEmpty ? "" : "\n") + shared
                }
            }
            if title.isEmpty, let shared = item.attributedTitle?.string { title = shared }
        }
    }

    func save() -> Bool {
        do {
            try NoteStore.save(Note(kind: .url, target: target, label: title.isEmpty ? target : title, text: text))
            return true
        } catch {
            self.error = "Couldn't save the note: \(error)"
            return false
        }
    }
}

struct ShareView: View {
    @ObservedObject var draft: ShareDraft
    let finish: (Bool) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if !draft.target.isEmpty {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(draft.title.isEmpty ? draft.target : draft.title).lineLimit(1)
                                Text(draft.target).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        } icon: {
                            Image(systemName: "globe").foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    } footer: {
                        Text("Saved as a note for this page.")
                    }
                }
                Section {
                    TextField("Write a note…", text: $draft.text, axis: .vertical)
                        .lineLimit(6...12)
                        .focused($focused)
                }
                if let error = draft.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .overlay { if draft.loading { ProgressView() } }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { finish(false) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if draft.save() { finish(true) } }
                        .fontWeight(.semibold)
                        .disabled(draft.loading || draft.target.isEmpty && draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .tint(.notesAccent)
    }
}
