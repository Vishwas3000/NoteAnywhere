import AppKit
import Carbon
import SwiftUI

/// Search hits for `query`; a hit expands in place into an editor. Used by the hotkey popup and the overlay.
struct SearchResultsView: View {
    let query: String
    @ObservedObject private var model = NotesModel.shared
    @State private var hits: [SearchIndex.Hit] = []
    @State private var expanded: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if hits.isEmpty {
                    Text("No matching notes").foregroundStyle(.secondary).padding(8)
                }
                ForEach(hits, id: \.note.id) { hit in
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            expanded = expanded == hit.note.id ? nil : hit.note.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label { Text(hit.note.source) } icon: { NoteIcon(note: hit.note, size: 14) }
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(hit.note.text.isEmpty ? "Empty note" : hit.note.text).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if expanded == hit.note.id {
                            TextEditor(text: model.binding(hit.note.id, \.text))
                                .frame(height: 120)
                                .scrollContentBackground(.hidden)
                                .padding(4)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(8)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))  // debounce typing
            guard !Task.isCancelled else { return }
            hits = await model.search(query)
        }
    }
}

extension Note {
    /// "App · Xcode" / "Site · github.com"
    var source: String { kind == .app ? "App · \(label)" : "Site · \(target)" }
}

/// Spotlight-style search panel toggled by a global hotkey (⌥⇧Space).
final class SearchPopup: NSObject, NSWindowDelegate {
    static let shared = SearchPopup()
    private var hotKey: EventHotKeyRef?

    private lazy var panel: NSPanel = {
        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: SearchPopupView { [weak self] in self?.hide() })
        return panel
    }()

    func start() {
        // Carbon hotkeys need no Accessibility permission. The C handler can't capture, hence the shared instance.
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { SearchPopup.shared.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey | shiftKey),
                                         EventHotKeyID(signature: OSType(0x4D4E5345), id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { NSLog("MemoryNotes: ⌥⇧Space is taken by another app (\(status))") }
    }

    func toggle() {
        if panel.isVisible { return hide() }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private func hide() { panel.orderOut(nil) }

    func windowDidResignKey(_ notification: Notification) { hide() }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }  // Escape
}

private struct SearchPopupView: View {
    let close: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search all notes…", text: $query)
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($focused)
                .onExitCommand(perform: close)
            Divider()
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Type to search by meaning or keyword.").foregroundStyle(.secondary)
                Spacer()
            } else {
                SearchResultsView(query: query)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 300)
        .onAppear { focused = true }
    }
}
