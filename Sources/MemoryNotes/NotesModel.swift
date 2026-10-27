import AppKit
import Combine
import notify
import SwiftUI

/// Shared state for the main window and the overlay: all notes, plus which app is in front.
final class NotesModel: ObservableObject {
    static let shared = NotesModel()

    @Published private(set) var notes = NoteStore.loadAll()
    /// One entry per note per day it was edited; feeds the calendar.
    @Published private(set) var snapshots = NoteStore.loadHistory()
    /// A note to select in the main window, e.g. after clicking a link to it inside another note.
    @Published var openRequest: String?
    /// The last frontmost app that isn't MemoryNotes itself.
    @Published private(set) var frontApp: NSRunningApplication?

    private var notifyToken: Int32 = 0
    private var indexing: AnyCancellable?

    private init() {
        // Every committed write (here or in the browser host process) posts this Darwin notification.
        notify_register_dispatch(NoteStore.changed, &notifyToken, .main) { [weak self] _ in self?.reload() }

        // Re-embed changed notes once typing pauses; the first run downloads the model if needed.
        indexing = $notes.debounce(for: .seconds(2), scheduler: RunLoop.main).sink { notes in
            Task { await SearchIndex.shared.update(notes) }
        }

        frontApp = Self.otherApp(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = Self.otherApp(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication) {
                self?.frontApp = app
            }
        }
    }

    private static func otherApp(_ app: NSRunningApplication?) -> NSRunningApplication? {
        app?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app
    }

    func reload() {
        let fresh = NoteStore.loadAll()
        if fresh != notes { notes = fresh }
        let history = NoteStore.loadHistory()
        if history != snapshots { snapshots = history }
    }

    func search(_ query: String) async -> [SearchIndex.Hit] {
        await SearchIndex.shared.search(query, in: notes)
    }

    func notes(forApp bundleID: String) -> [Note] {
        notes.filter { $0.kind == .app && $0.target == bundleID }
    }

    @discardableResult
    func add(kind: Note.Kind, target: String, label: String) -> Note {
        let note = Note(kind: kind, target: target, label: label)
        notes.append(note)
        persist(note)
        return note
    }

    func delete(_ id: String) {
        notes.removeAll { $0.id == id }
        snapshots.removeAll { $0.note.id == id }
        do { try NoteStore.delete(id) } catch { NSLog("MemoryNotes: delete failed: \(error)") }
    }

    func binding(_ id: String, _ field: WritableKeyPath<Note, String>) -> Binding<String> {
        Binding(
            get: { self.notes.first { $0.id == id }?[keyPath: field] ?? "" },
            set: { value in
                guard let i = self.notes.firstIndex(where: { $0.id == id }) else { return }
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
