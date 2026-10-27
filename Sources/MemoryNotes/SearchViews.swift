import AppKit
import Carbon
import SwiftUI

/// Search hits for `query`; a hit expands in place into an editor. Used by the hotkey popup and the overlay.
/// The popup drives `selection` (↑/↓) and bumps `submits` (Return) from its search field, which keeps focus.
struct SearchResultsView: View {
    let query: String
    @Binding var selection: Int
    var submits = 0
    @ObservedObject private var model = NotesModel.shared
    @State private var hits: [SearchIndex.Hit] = []
    @State private var searched: String?  // the query `hits` belongs to; no empty state while still debouncing
    @State private var expanded: String?

    init(query: String, selection: Binding<Int> = .constant(-1), submits: Int = 0) {
        self.query = query
        _selection = selection
        self.submits = submits
    }

    var body: some View {
        Group {
            if searched == query && hits.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(hits.enumerated()), id: \.element.note.id) { index, hit in
                                row(hit, selected: index == selection).id(hit.note.id)
                            }
                        }
                    }
                    .onChange(of: selection) { _, index in
                        guard !hits.isEmpty else { return }
                        let clamped = min(max(index, 0), hits.count - 1)
                        if clamped != index { return selection = clamped }
                        withAnimation { proxy.scrollTo(hits[clamped].note.id) }
                    }
                }
            }
        }
        .onChange(of: submits) {
            guard hits.indices.contains(selection) else { return }
            toggle(hits[selection].note.id)
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))  // debounce typing
            guard !Task.isCancelled else { return }
            hits = await model.search(query)
            searched = query
            selection = 0
        }
    }

    private func toggle(_ id: String) {
        expanded = expanded == id ? nil : id
    }

    private func row(_ hit: SearchIndex.Hit, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { toggle(hit.note.id) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label { Text(hit.note.source) } icon: { NoteIcon(note: hit.note, size: 14) }
                        .font(.caption).foregroundStyle(.secondary)
                    Text(hit.note.text.isEmpty ? "Empty note" : hit.note.text).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Press Return to edit")
            if expanded == hit.note.id {
                NoteEditor(noteID: hit.note.id, toolbar: false)
                    .frame(height: 140)
                    .padding(4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(8)
        .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.quinary),
                    in: RoundedRectangle(cornerRadius: 8))
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
        panel.makeFloating()
        panel.standardWindowButton(.closeButton)?.isHidden = true  // Escape closes it; no greyed-out traffic lights
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
    @State private var selection = 0
    @State private var submits = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                TextField("Search all notes…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onExitCommand(perform: close)
                    .onKeyPress(.downArrow) { selection += 1; return .handled }
                    .onKeyPress(.upArrow) { selection -= 1; return .handled }
                    .onSubmit { submits += 1 }
            }
            Divider()
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Type to search by meaning or keyword. ↑↓ to choose, Return to edit.").foregroundStyle(.secondary)
                Spacer()
            } else {
                SearchResultsView(query: query, selection: $selection, submits: submits)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 300)
        .floatingBackground()
        .onAppear { focused = true }
    }
}
