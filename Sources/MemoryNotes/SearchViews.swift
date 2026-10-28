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
    @Environment(\.colorSchemeContrast) private var contrast
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
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(hits.enumerated()), id: \.element.note.id) { index, hit in
                                // The live note, so the title follows edits made in the expanded editor.
                                row(model.notes.first { $0.id == hit.note.id } ?? hit.note, index: index).id(hit.note.id)
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

    /// Apple Notes style: bold title, then the preview, then where the note lives and when it was edited.
    private func row(_ note: Note, index: Int) -> some View {
        let selected = index == selection
        let isOpen = expanded == note.id
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                selection = index
                toggle(note.id)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    NoteIcon(note: note, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title).font(.headline).lineLimit(1)
                        Text(note.preview.isEmpty ? "No additional text" : note.preview)
                            .foregroundStyle(note.preview.isEmpty ? .tertiary : .secondary)
                            .lineLimit(1)
                        Text("\(note.source) · \(note.editedAgo)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(isOpen ? "Closes the editor" : "Opens the note for editing")
            if isOpen {
                NoteEditor(noteID: note.id, toolbar: false, fit: 44...240)
                    .padding(6)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(8)
        .background(selected ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if selected && contrast == .increased { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary) }
        }
    }
}

extension Note {
    /// "App · Xcode" / "Site · github.com"
    var source: String { kind == .app ? "App · \(place)" : "Site · \(place)" }
    /// "5 minutes ago", "yesterday"
    var editedAgo: String { edited.formatted(.relative(presentation: .named, unitsStyle: .wide)) }
}

/// Spotlight-style search panel toggled by a global hotkey (⌥⇧Space).
final class SearchPopup: NSObject, NSWindowDelegate {
    static let shared = SearchPopup()

    private lazy var panel: NSPanel = {
        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.makeFloating()
        panel.title = "Search Notes"  // hidden, but VoiceOver announces it
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
        HotKeys.register(kVK_Space, optionKey | shiftKey, name: "⌥⇧Space") { [weak self] in self?.toggle() }
    }

    func toggle() {
        if panel.isVisible { return hide() }
        panel.moveToMouseScreen()
        panel.center()  // centers on the panel's current screen
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
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.title).foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search all notes", text: $query, prompt: Text("Search notes"))
                    .textFieldStyle(.plain)
                    .font(.title)
                    .focused($focused)
                    .onExitCommand(perform: close)
                    .onKeyPress(.downArrow) { selection += 1; return .handled }
                    .onKeyPress(.upArrow) { selection -= 1; return .handled }
                    .onSubmit { submits += 1 }
                    .accessibilityHint("Up and Down Arrow choose a note, Return edits it, Escape closes")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Divider()
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("Search Your Notes", systemImage: "note.text",
                                           description: Text("Find any note by meaning or keyword, from every app and website."))
                } else {
                    SearchResultsView(query: query, selection: $selection, submits: submits).padding(8)
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 16) {
                keyHint("↑↓", "Select")
                keyHint("↩", "Edit")
                keyHint("esc", "Close")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityHidden(true)  // the search field's hint tells VoiceOver the same
        }
        .frame(width: 600, height: 440)
        .floatingBackground()
        .tint(.yellow)
        .onAppear { focused = true }
    }

    private func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .fontWeight(.medium)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(action)
        }
    }
}
