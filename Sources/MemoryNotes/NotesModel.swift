import AppKit
import Combine
import notify
import SwiftUI

/// Which app, and which place in it, is in front. Its own object, so views that don't show it (the main window)
/// don't redraw every time a window title changes.
final class FrontWindow: ObservableObject {
    static let shared = FrontWindow()
    @Published fileprivate(set) var app: NSRunningApplication?
    @Published fileprivate(set) var context: String?
}

/// Shared state for the main window and the overlay: all notes, plus which app is in front.
final class NotesModel: ObservableObject {
    static let shared = NotesModel()

    @Published private(set) var notes = NoteStore.loadAll()
    @Published private(set) var folders = NoteStore.folders()
    /// One entry per note per day it was edited; feeds the calendar.
    @Published private(set) var snapshots = NoteStore.loadHistory()
    /// A note to select in the main window, e.g. after clicking a link to it inside another note.
    @Published var openRequest: String?
    /// A search to run in the main window, e.g. "#ml" after ⌘-clicking that tag in a note.
    @Published var searchRequest: String?
    /// A day ("yyyy-MM-dd") to show in the calendar, e.g. after ⌘-clicking a date in a note.
    @Published var calendarRequest: String?
    /// The last frontmost app that isn't MemoryNotes itself.
    var frontApp: NSRunningApplication? { FrontWindow.shared.app }
    /// Where in that app you are, as an app-note target: "bundle.id/Workspace/Channel" (just "bundle.id" without
    /// the Accessibility permission or a useful window title).
    var frontContext: String? { FrontWindow.shared.context }

    private let titles = WindowTitleWatcher()

    private var notifyToken: Int32 = 0
    private var indexing: AnyCancellable?

    private init() {
        // Every committed write (here or in the browser host process) posts this Darwin notification.
        notify_register_dispatch(NoteStore.changed, &notifyToken, .main) { [weak self] _ in self?.reload() }

        // Re-embed changed notes once typing pauses; the first run downloads the model if needed.
        indexing = $notes.debounce(for: .seconds(2), scheduler: RunLoop.main).sink { notes in
            Task { await SearchIndex.shared.update(notes) }
        }

        titles.onChange = { [weak self] title, conversation in
            guard let self, let app = self.frontApp, let id = app.bundleIdentifier else { return }
            let context = WindowContext.target(bundleID: id, appName: app.localizedName ?? id, title: title, conversation: conversation)
            if context != self.frontContext { FrontWindow.shared.context = context }
        }
        WindowTitleWatcher.requestPermission()
        setFront(Self.otherApp(NSWorkspace.shared.frontmostApplication))
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = Self.otherApp(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication) {
                self?.setFront(app)
            }
        }
    }

    private func setFront(_ app: NSRunningApplication?) {
        FrontWindow.shared.app = app
        titles.watch(app)  // reports the window title right away, which sets frontContext
    }

    private static func otherApp(_ app: NSRunningApplication?) -> NSRunningApplication? {
        app?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app
    }

    func reload() {
        let fresh = NoteStore.loadAll()
        if fresh != notes { notes = fresh }
        let freshFolders = NoteStore.folders()
        if freshFolders != folders { folders = freshFolders }
        let history = NoteStore.loadHistory()
        if history != snapshots { snapshots = history }
    }

    func search(_ query: String) async -> [SearchIndex.Hit] {
        await SearchIndex.shared.search(query, in: notes)
    }

    /// App notes for a context and everything under it (same rule as web pages: parents see children).
    func notes(inContext context: String) -> [Note] {
        notes.filter { $0.kind == .app && ($0.target == context || $0.target.hasPrefix(context + "/")) }
    }

    @discardableResult
    func add(kind: Note.Kind, target: String, label: String, folderID: String? = nil, text: String = "") -> Note {
        var note = Note(kind: kind, target: target, label: label, text: text)
        notes.append(note)
        persist(note)
        if folderID != nil {
            note.folderID = folderID
            setMeta(note)
        }
        return note
    }

    /// "Add page" on highlighted text: a plain note titled with it, in the same folder, with a ↖ link back to the note
    /// it came from (the highlight there links here), so a question can point to the answer found later.
    func addPage(titled title: String, from parentID: String) -> Note {
        let parent = notes.first { $0.id == parentID }
        return add(kind: .url, target: "", label: "", folderID: parent?.folderID, text: Self.pageText(title, backTo: parent))
    }

    /// "Why does sync lag?\n\n↖ [Sync notes](note://ID)\n\n": the highlight on one line as the title, then the way back.
    static func pageText(_ title: String, backTo parent: Note?) -> String {
        let line = title.split(whereSeparator: \.isNewline).joined(separator: " ")
        let back = parent.map { "\n\n↖ [\($0.title.replacingOccurrences(of: "]", with: "\\]"))](note://\($0.id))" } ?? ""
        return line + back + "\n\n"
    }

    /// A copy with the same text, place, folder and colour (unpinned), like Apple Notes' Duplicate.
    @discardableResult
    func duplicate(_ note: Note) -> Note {
        var copy = add(kind: note.kind, target: note.target, label: note.label, folderID: note.folderID, text: note.text)
        copy.color = note.color
        copy.folderID = note.folderID
        setMeta(copy)
        return copy
    }

    /// Pin, colour or folder changes (see NoteStore.saveMeta for why they don't count as edits).
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

    @discardableResult
    func addFolder(_ name: String) -> Folder {
        let folder = Folder(name: name)
        folders.append(folder)
        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        do { try NoteStore.saveFolder(folder) } catch { NSLog("MemoryNotes: folder save failed: \(error)") }
        return folder
    }

    func renameFolder(_ id: String, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = name
        do { try NoteStore.saveFolder(folders[i]) } catch { NSLog("MemoryNotes: folder save failed: \(error)") }
    }

    func deleteFolder(_ id: String) {
        folders.removeAll { $0.id == id }
        for i in notes.indices where notes[i].folderID == id { notes[i].folderID = nil }
        do { try NoteStore.deleteFolder(id) } catch { NSLog("MemoryNotes: folder delete failed: \(error)") }
    }

    func delete(_ id: String) {
        notes.removeAll { $0.id == id }
        snapshots.removeAll { $0.note.id == id }
        do { try NoteStore.delete(id) } catch { NSLog("MemoryNotes: delete failed: \(error)") }
    }

    // MARK: Locked notes

    /// The editor's text: decrypted while locked notes are unlocked, re-sealed (same salt, so it's quick) on every edit.
    @MainActor
    func textBinding(_ id: String) -> Binding<String> {
        let raw = binding(id, \.text)
        return Binding(get: {
            guard let note = self.notes.first(where: { $0.id == id }), note.locked else { return raw.wrappedValue }
            return LockSession.shared.password.flatMap { try? NoteLock.open(note.text, password: $0) } ?? ""
        }, set: { value in
            guard let note = self.notes.first(where: { $0.id == id }), note.locked else { return raw.wrappedValue = value }
            guard let password = LockSession.shared.password,
                  let sealed = try? NoteLock.seal(value, password: password, reusing: note.text) else { return }
            raw.wrappedValue = sealed
        })
    }

    /// Needs LockSession to be unlocked (or a password just set).
    @MainActor
    func lock(_ id: String) {
        guard let password = LockSession.shared.password, let i = notes.firstIndex(where: { $0.id == id }), !notes[i].locked,
              let sealed = try? NoteLock.seal(notes[i].text, password: password) else { return }
        notes[i].text = sealed
        notes[i].locked = true
        do { try NoteStore.setLocked(id, text: sealed, locked: true) } catch { NSLog("MemoryNotes: lock failed: \(error)") }
        Task { await SearchIndex.shared.forget(id) }
    }

    @MainActor
    func removeLock(_ id: String) {
        guard let password = LockSession.shared.password, let i = notes.firstIndex(where: { $0.id == id }), notes[i].locked,
              let plain = try? NoteLock.open(notes[i].text, password: password) else { return }
        notes[i].text = plain
        notes[i].locked = false
        do { try NoteStore.setLocked(id, text: plain, locked: false) } catch { NSLog("MemoryNotes: unlock failed: \(error)") }
    }

    /// Ticks or unticks a dated checklist line from the calendar.
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
