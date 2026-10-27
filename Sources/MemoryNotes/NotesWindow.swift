import AppKit
import SwiftUI

enum WindowMode: String, CaseIterable { case notes = "Notes", calendar = "Calendar" }

/// What the menu commands can do in the focused notes window.
struct WindowActions {
    var newWebsiteNote: () -> Void
    var findNotes: () -> Void
    var show: (WindowMode) -> Void
    var deleteSelected: (() -> Void)?
}

extension FocusedValues {
    @Entry var windowActions: WindowActions?
}

/// Every note in one place: a sidebar of app and website notes (including ones written in the browser),
/// with the selected note or the calendar on the right.
struct NotesWindow: View {
    @ObservedObject private var model = NotesModel.shared
    @State private var mode = WindowMode.notes
    @State private var selection: String?
    @State private var query = ""
    @State private var hits: [SearchIndex.Hit] = []
    @State private var searchedQuery = ""  // the query `hits` belong to, so "no results" never flashes mid-debounce
    @State private var searchFocused = false
    @State private var pendingDelete: Note?
    @FocusState private var targetFocused: Bool

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            switch mode {
            case .calendar: CalendarView()
            case .notes: detail
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(WindowMode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) { newNoteMenu }
            if mode == .notes, let note = selectedNote {
                ToolbarItem {
                    Button { pendingDelete = note } label: { Label("Delete Note", systemImage: "trash") }
                        .help("Delete Note")
                }
            }
        }
        .focusedSceneValue(\.windowActions, WindowActions(
            newWebsiteNote: newWebsiteNote,
            findNotes: { mode = .notes; searchFocused = true },
            show: { mode = $0 },
            deleteSelected: selectedNote.map { note in { pendingDelete = note } }
        ))
        .confirmationDialog("Delete this note?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { note in
            Button("Delete", role: .destructive) { delete(note) }
        } message: { note in
            Text(note.text.isEmpty ? "This empty note will be removed." : "“\(firstLine(note))” will be removed.")
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var selectedNote: Note? { selection.flatMap { id in model.notes.first { $0.id == id } } }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            if searching {
                if !hits.isEmpty {
                    Section("Results") {
                        ForEach(hits, id: \.note.id) { row($0.note, title: $0.note.source) }
                    }
                }
            } else {
                let apps = model.notes.filter { $0.kind == .app }
                let sites = model.notes.filter { $0.kind == .url }
                if !apps.isEmpty {
                    Section("Apps") { ForEach(apps) { row($0, title: $0.place) } }
                }
                if !sites.isEmpty {
                    Section("Websites") { ForEach(sites) { row($0, title: $0.target.isEmpty ? "New website note" : $0.place) } }
                }
            }
        }
        .overlay {
            if searching, searchedQuery == query, hits.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if !searching, model.notes.isEmpty {
                ContentUnavailableView("No Notes", systemImage: "note.text",
                                       description: Text("Press ⌘N for a website note, or use + to add one for an app."))
            }
        }
        .searchable(text: $query, isPresented: $searchFocused, placement: .sidebar, prompt: "Search by meaning or keyword")
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))  // debounce typing
            guard !Task.isCancelled else { return }
            hits = await model.search(query)
            searchedQuery = query
        }
        .onChange(of: model.openRequest) { _, id in
            guard let id else { return }
            query = ""
            mode = .notes
            selection = id
            model.openRequest = nil
        }
        .onChange(of: selection) { _, id in if id != nil { mode = .notes } }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    }

    private func row(_ note: Note, title: String) -> some View {
        HStack(spacing: 8) {
            NoteIcon(note: note, size: 20)
            VStack(alignment: .leading) {
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(firstLine(note)).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .tag(note.id)
        .contextMenu {
            if note.kind == .url, let url = URL(string: "https://\(note.target)") {
                Button("Open Page") { NSWorkspace.shared.open(url) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                Divider()
            }
            Button("Delete…", role: .destructive) { pendingDelete = note }
        }
    }

    private func firstLine(_ note: Note) -> String {
        note.text.split(separator: "\n").first.map(String.init) ?? "Empty note"
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let note = selectedNote {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    NoteIcon(note: note, size: 28)
                    if note.kind == .url {
                        TextField("Page address, e.g. github.com/vercel/next.js", text: targetBinding(note.id))
                            .textFieldStyle(.roundedBorder)
                            .focused($targetFocused)
                    } else {
                        VStack(alignment: .leading) {
                            Text(note.place).font(.headline)
                            Text(note.target.prefix { $0 != "/" }).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                NoteEditor(noteID: note.id)
            }
            .padding()
        } else {
            ContentUnavailableView("No Note Selected", systemImage: "note.text",
                                   description: Text("Pick a note in the sidebar, or press ⌘N to start one."))
        }
    }

    // MARK: Actions

    private var newNoteMenu: some View {
        Menu {
            Button("New Website Note", action: newWebsiteNote)
            Menu("New Note for App") {
                ForEach(runningApps(), id: \.processIdentifier) { app in
                    Button {
                        selection = model.add(kind: .app, target: app.bundleIdentifier!, label: app.localizedName ?? "").id
                    } label: {
                        Label { Text(app.localizedName ?? "") } icon: { Image(nsImage: smallIcon(app)) }
                    }
                }
            }
        } label: {
            Label("New Note", systemImage: "square.and.pencil")
        } primaryAction: {
            newWebsiteNote()
        }
        .help("New Note")
    }

    private func newWebsiteNote() {
        mode = .notes
        query = ""
        selection = model.add(kind: .url, target: "", label: "").id
        targetFocused = true
    }

    private func delete(_ note: Note) {
        if selection == note.id { selection = nil }
        model.delete(note.id)
    }

    /// Accepts pasted URLs: strips the scheme, "www." and a trailing "/" so the target matches what the extension sends.
    private func targetBinding(_ id: String) -> Binding<String> {
        let raw = model.binding(id, \.target)
        return Binding(get: { raw.wrappedValue }, set: { value in
            raw.wrappedValue = value.replacing(#/^https?:\/\//#, with: "").replacing(#/^www\./#, with: "")
        })
    }

    private func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func smallIcon(_ app: NSRunningApplication) -> NSImage {
        let icon = (app.icon?.copy() as? NSImage) ?? NSImage()  // copy: NSRunningApplication shares its icon instance
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}
