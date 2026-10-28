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
