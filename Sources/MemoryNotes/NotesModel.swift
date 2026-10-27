import AppKit
import Combine
import SwiftUI

/// Shared state for the main window and the overlay: all notes, plus which app is in front.
final class NotesModel: ObservableObject {
    static let shared = NotesModel()

    @Published private(set) var notes = NoteStore.loadAll()
    /// One entry per note per day it was edited; feeds the calendar.
    @Published private(set) var snapshots = NoteStore.loadHistory()
    /// The last frontmost app that isn't MemoryNotes itself.
    @Published private(set) var frontApp: NSRunningApplication?

    private var watcher: DispatchSourceFileSystemObject?
    private var indexing: AnyCancellable?

    private init() {
        // Notes made before the calendar existed get a snapshot on their last-edited day.
        for note in notes where !FileManager.default.fileExists(atPath: NoteStore.historyDir.appendingPathComponent(note.id).path) {
            try? NoteStore.save(note)
        }
        snapshots = NoteStore.loadHistory()

        // Atomic writes rename into the folder, so a directory watch sees every save/delete from the browser host.
        let fd = open(NoteStore.dir.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in self?.reload() }
            source.setCancelHandler { close(fd) }
            source.resume()
            watcher = source
        }

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
