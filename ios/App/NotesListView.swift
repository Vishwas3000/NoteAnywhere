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
                    ForEach(NoteDates.sections(model.notes)) { section in
                        Section { ForEach(section.notes) { row($0) } } header: { header(section.title) }
                    }
                }
            }
            .overlay { emptyState }
            .navigationTitle("Notes")
            .searchable(text: $query, prompt: "Search by meaning or keyword")
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(300))  // debounce typing
                guard !Task.isCancelled, searching else { return }
                hits = await model.search(query)
                searchedQuery = query
            }
            .refreshable { model.reload() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { newNote() } label: { Label("New Note", systemImage: "plus") }
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
            .task { if let id = UserDefaults.standard.string(forKey: "openNote"), path.isEmpty { path = [id] } }  // screenshots
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
                                   description: Text("Tap + to write one, or share a page or some text to MemoryNotes."))
        }
    }

    /// Bold, sentence-case headers like Notes, instead of the list's small grey ones.
    private func header(_ title: String) -> some View {
        Text(title).font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
    }

    private func row(_ note: Note) -> some View {
        NavigationLink(value: note.id) {
            NoteRow(note: note, date: NoteDates.short(note.edited))
        }
        .swipeActions {
            Button { delete(note) } label: { Label("Delete", systemImage: "trash") }.tint(.red)
        }
        .contextMenu {
            if let url = note.pageURL {
                Link(destination: url) { Label("Open Page", systemImage: "safari") }
                Button { UIPasteboard.general.url = url } label: { Label("Copy Link", systemImage: "link") }
            }
            ShareLink(item: note.text) { Label("Share", systemImage: "square.and.arrow.up") }
            Divider()
            Button(role: .destructive) { delete(note) } label: { Label("Delete", systemImage: "trash") }
        }
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
            Text(note.title).font(.headline).lineLimit(1)
            (Text(date) + Text("  ") + Text(note.preview.isEmpty ? "No additional text" : note.preview).foregroundStyle(.secondary))
                .font(.subheadline)
                .lineLimit(1)
            if !note.target.isEmpty {
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
