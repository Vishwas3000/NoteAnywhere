import Combine
import notify
import SwiftUI

/// All notes and their daily snapshots. Reloads whenever any process saves: this app, the Share or Safari
/// extension, or a sync pull. Same surface as the Mac's NotesModel, minus the front-app tracking.
final class NotesModel: ObservableObject {
    static let shared = NotesModel()

    @Published private(set) var notes = NoteStore.loadAll()
    @Published private(set) var folders = NoteStore.folders()
    /// One entry per note per day it was edited; feeds the calendar.
    @Published private(set) var snapshots = NoteStore.loadHistory()
    /// A search for the Notes tab to run, e.g. "#ml" after a #tag is opened in the editor.
    @Published var searchRequest: String?
    /// A day ("yyyy-MM-dd") for the Calendar tab to show, after a date is opened in the editor.
    @Published var calendarRequest: String?
    /// The note to move into a folder the user is about to name (RootView asks for the name).
    @Published var newFolderFor: String?

    private var notifyToken: Int32 = 0
    private var indexing: AnyCancellable?

    private init() {
        notify_register_dispatch(NoteStore.changed, &notifyToken, .main) { [weak self] _ in self?.reload() }
        // Re-embed changed notes once typing pauses, but only once the user's first search has downloaded the model:
        // 90 MB shouldn't download on launch, maybe over cellular.
        indexing = $notes.debounce(for: .seconds(2), scheduler: RunLoop.main).sink { notes in
            guard SearchIndex.hasModel else { return }
            Task { await SearchIndex.shared.update(notes) }
        }
    }

    func note(_ id: String) -> Note? { notes.first { $0.id == id } }

    func reload() {
        let fresh = NoteStore.loadAll()
        if fresh != notes { notes = fresh }
        let freshFolders = NoteStore.folders()
        if freshFolders != folders { folders = freshFolders }
        let history = NoteStore.loadHistory()
        if history != snapshots { snapshots = history }
    }

    func search(_ query: String) async -> [SearchIndex.Hit] {
        let hits = await SearchIndex.shared.search(query, in: notes)
        if SearchIndex.hasModel { Task { await SearchIndex.shared.update(notes) } }  // first search: index the rest now
        return hits
    }

    /// A note with no app or website: the phone has neither, and the Mac shows such a note as a website note
    /// still waiting for its address (the same thing its own ⌘N makes).
    func add() -> Note {
        let note = Note(kind: .url, target: "", label: "")
        notes.append(note)
        persist(note)
        return note
    }

    /// A copy with the same text, place, folder and colour (unpinned), like Apple Notes' Duplicate.
    func duplicate(_ note: Note) {
        var copy = Note(kind: note.kind, target: note.target, label: note.label, text: note.text)
        notes.append(copy)
        persist(copy)
        copy.folderID = note.folderID
        copy.color = note.color
        setMeta(copy)
    }

    /// Pin, colour or folder changes (NoteStore.saveMeta: they don't count as edits).
    func update(_ id: String, _ change: (inout Note) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[i])
        setMeta(notes[i])
    }

    private func setMeta(_ note: Note) {
        if let i = notes.firstIndex(where: { $0.id == note.id }) {
            notes[i] = note
            notes[i].updatedAt += 1
        }
        do { try NoteStore.saveMeta(note) } catch { NSLog("MemoryNotes: save failed: \(error)") }
    }

    func addFolder(_ name: String) -> Folder {
        let folder = Folder(name: name)
        folders.append(folder)
        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        do { try NoteStore.saveFolder(folder) } catch { NSLog("MemoryNotes: folder save failed: \(error)") }
        return folder
    }

    func delete(_ id: String) {
        notes.removeAll { $0.id == id }
        snapshots.removeAll { $0.note.id == id }
        do { try NoteStore.delete(id) } catch { NSLog("MemoryNotes: delete failed: \(error)") }
    }

    /// Ticks or unticks a dated task from the calendar, by flipping its checkbox in the note's Markdown.
    func toggleTask(_ item: DatedLine) {
        let text = binding(item.noteID, \.text)
        var lines = text.wrappedValue.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.indices.contains(item.line),
              let box = lines[item.line].firstMatch(of: #/^\s*[-*+]\s+\[([ xX])\]/#) else { return }
        lines[item.line].replaceSubrange(box.1.startIndex..<box.1.endIndex, with: box.1 == " " ? "x" : " ")
        text.wrappedValue = lines.joined(separator: "\n")
    }

    func binding(_ id: String, _ field: WritableKeyPath<Note, String>) -> Binding<String> {
        Binding(
            get: { self.note(id)?[keyPath: field] ?? "" },
            set: { value in
                guard let i = self.notes.firstIndex(where: { $0.id == id }), self.notes[i][keyPath: field] != value else { return }
                self.notes[i][keyPath: field] = value
                self.notes[i].updatedAt = Date().timeIntervalSince1970 * 1000
                self.persist(self.notes[i])
            }
        )
    }

    private func persist(_ note: Note) {
        do { try NoteStore.save(note) } catch { NSLog("MemoryNotes: save failed: \(error)") }
    }
}
