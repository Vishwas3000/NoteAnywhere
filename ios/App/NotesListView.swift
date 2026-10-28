import SwiftUI

/// Every note, newest edit first, grouped like Apple Notes: Today, Yesterday, Previous 7 Days, …
struct NotesListView: View {
    @ObservedObject private var model = NotesModel.shared
    @State private var path: [String] = []
    @State private var query = ""
    @State private var hits: [SearchIndex.Hit] = []
    @State private var searchedQuery = ""  // the query `hits` belong to, so "no results" never flashes mid-debounce
    @State private var pendingDelete: Note?
    @State private var draft: String?  // a note made with +, dropped again if left empty
    @State private var folder: String?  // nil: All Notes

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if searching {
                    if !hits.isEmpty {
                        // The live note, so a result follows edits made after the search.
                        Section { ForEach(hits, id: \.note.id) { row(model.note($0.note.id) ?? $0.note) } } header: { header("Results") }
                    }
                } else {
                    let shown = model.notes.filter { folder == nil || $0.folderID == folder }
                    let pinned = shown.filter(\.pinned).sorted { $0.updatedAt > $1.updatedAt }
                    if !pinned.isEmpty {
                        Section { ForEach(pinned) { row($0) } } header: { header("Pinned") }
                    }
                    ForEach(NoteDates.sections(shown.filter { !$0.pinned })) { section in
                        Section { ForEach(section.notes) { row($0) } } header: { header(section.title) }
                    }
                }
            }
            .overlay { emptyState }
            .navigationTitle(model.folders.first { $0.id == folder }?.name ?? "Notes")
            .searchable(text: $query, prompt: "Search by meaning or keyword")
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(300))  // debounce typing
                guard !Task.isCancelled, searching else { return }
                hits = await model.search(query)
                searchedQuery = query
            }
            .refreshable { model.reload() }
            .onChange(of: model.searchRequest, initial: true) {
                guard let request = model.searchRequest else { return }
                path = []
                query = request
                model.searchRequest = nil
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { newNote() } label: { Label("New Note", systemImage: "plus") }
                }
                if !model.folders.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker("Folder", selection: $folder) {
                                Label("All Notes", systemImage: "tray.full").tag(String?.none)
                                ForEach(model.folders) { Label($0.name, systemImage: "folder").tag(Optional($0.id)) }
                            }
                        } label: {
                            Label("Folders", systemImage: folder == nil ? "folder" : "folder.fill")
                        }
                    }
                }
            }
            .navigationDestination(for: String.self) { NoteDetailView(noteID: $0) }
            .onChange(of: path) {
                guard let id = draft, !path.contains(id) else { return }
                draft = nil
                if model.note(id)?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { model.delete(id) }
            }
            .confirmationDialog("Delete this note?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { note in
                Button("Delete Note", role: .destructive) { model.delete(note.id) }
            } message: { note in
                Text("“\(note.title)” will be removed.")
            }
            #if DEBUG
            .task {  // screenshots: -openNote <id>, -search <query>
                let defaults = UserDefaults.standard
                if let id = defaults.string(forKey: "openNote"), !id.isEmpty, path.isEmpty { path = [id] }
                if let search = defaults.string(forKey: "search"), !search.isEmpty { model.searchRequest = search }
            }
            #endif
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if searching {
            if searchedQuery != query {
                VStack(spacing: 8) {
                    ProgressView()
                    if !SearchIndex.hasModel {
                        Text("The first search downloads the search model (about 90 MB).")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .padding(32)
            } else if hits.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        } else if model.notes.isEmpty {
            ContentUnavailableView("No Notes", systemImage: "note.text",
                                   description: Text("Tap + to write one, or share a page or some text to NoteAnywhere."))
        }
    }

    /// Bold, sentence-case headers like Notes, instead of the list's small grey ones.
    private func header(_ title: String) -> some View {
        Text(title).font(.title3.bold()).foregroundStyle(Color.primary).textCase(nil)
    }

    private func row(_ note: Note) -> some View {
        NavigationLink(value: note.id) {
            NoteRow(note: note, date: NoteDates.short(note.edited))
        }
        .swipeActions {
            Button { delete(note) } label: { Label("Delete", systemImage: "trash") }.tint(.red)
        }
        .swipeActions(edge: .leading) {
            Button { model.update(note.id) { $0.pinned.toggle() } } label: {
                Label(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash.fill" : "pin.fill")
            }
            .tint(.notesAccent)
        }
        .contextMenu { NoteMenu(note: note) { delete(note) } }
    }

    /// Empty notes go at once; anything with text asks first.
    private func delete(_ note: Note) {
        if note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.delete(note.id) } else { pendingDelete = note }
    }

    private func newNote() {
        query = ""
        let note = model.add()
        draft = note.id
        path = [note.id]
    }
}

/// An Apple Notes list row: bold title; the date then the preview; the app or site it belongs to.
struct NoteRow: View {
    let note: Note
    let date: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let color = note.color {
                    Circle().fill(color.swatch).frame(width: 9, height: 9).accessibilityLabel("\(color.title) label")
                }
                if note.locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                Text(note.title).font(.headline).lineLimit(1)
            }
            (Text(date) + Text("  ") + Text(note.preview.isEmpty ? "No additional text" : note.preview).foregroundStyle(.secondary))
                .font(.subheadline)
                .lineLimit(1)
            if note.hasSource {
                HStack(spacing: 5) {
                    NoteIcon(note: note, size: 14)
                    Text(note.shortSource).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
