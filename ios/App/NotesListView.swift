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
    @State private var folder: String?  // nil: All Notes; Self.starred: the starred notes
    @State private var renaming: Folder?
    @State private var folderName = ""

    private static let starred = "starred"  // folder ids are UUIDs, so this never names a folder

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
                    let shown = model.notes.filter(isShown)
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
            .navigationTitle(title)
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
                ToolbarItem(placement: .topBarLeading) { filterMenu }
            }
            .navigationDestination(for: String.self) { NoteDetailView(noteID: $0) }
            .alert("Rename Folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $folderName)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    let name = folderName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, let id = renaming?.id { model.renameFolder(id, to: name) }
                }
            }
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
        } else if folder == Self.starred, !model.notes.contains(where: \.starred) {
            ContentUnavailableView("No Starred Notes", systemImage: "star",
                                   description: Text("Swipe right on a note, or touch and hold it, to star it."))
        }
    }

    private func isShown(_ note: Note) -> Bool {
        folder == Self.starred ? note.starred : folder == nil || note.folderID == folder
    }

    private var title: String {
        folder == Self.starred ? "Starred" : model.folders.first { $0.id == folder }?.name ?? "Notes"
    }

    /// What the list shows (all notes, the starred ones or a folder), the folder's Rename and Delete, and every #tag.
    private var filterMenu: some View {
        Menu {
            Picker("Folder", selection: $folder) {
                Label("All Notes", systemImage: "tray.full").tag(String?.none)
                Label("Starred", systemImage: "star").tag(Optional(Self.starred))
                ForEach(model.folders) { Label($0.name, systemImage: "folder").tag(Optional($0.id)) }
            }
            if let current = model.folders.first(where: { $0.id == folder }) {
                Section {
                    Button { folderName = current.name; renaming = current } label: { Label("Rename Folder…", systemImage: "pencil") }
                    Button(role: .destructive) {  // like the Mac: its notes go back to All Notes, none are deleted
                        folder = nil
                        model.deleteFolder(current.id)
                    } label: { Label("Delete Folder", systemImage: "trash") }
                }
            }
            let tags = tagCounts
            if !tags.isEmpty {
                Menu {
                    ForEach(tags, id: \.tag) { item in
                        Button { query = "#" + item.tag } label: {
                            Text("#" + item.tag)
                            Text(item.count == 1 ? "1 note" : "\(item.count) notes")
                        }
                    }
                } label: { Label("Tags", systemImage: "number") }
            }
        } label: {
            Label("Folders and Tags", systemImage: folder == nil ? "folder" : folder == Self.starred ? "star.fill" : "folder.fill")
        }
    }

    /// Every #tag in use with its number of notes, most used first, like the Mac sidebar's Tags.
    private var tagCounts: [(tag: String, count: Int)] {
        let counts = model.notes.flatMap(\.tags).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { (tag: $0.key, count: $0.value) }
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
            Button { model.update(note.id) { $0.starred.toggle() } } label: {
                Label(note.starred ? "Unstar" : "Star", systemImage: note.starred ? "star.slash.fill" : "star.fill")
            }
            .tint(.yellow)
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
                if note.locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                Text(note.title).font(.headline).lineLimit(1)
                if note.starred { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow).accessibilityLabel("Starred") }
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
        .overlay(alignment: .leading) {  // the colour label: a strip at the row's edge, like the Mac's sidebar
            if let color = note.color {
                Capsule().fill(color.swatch).frame(width: 4).padding(.vertical, 2).offset(x: -12)
                    .accessibilityLabel("\(color.title) label")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
