import Foundation
import Testing
@testable import MemoryNotes

/// Runs against a scratch database. NoteStore.root is fixed on first use, so this suite sets MEMORYNOTES_DIR before
/// touching it and refuses to run if some other test already opened the real store.
@Suite(.serialized) struct SyncStoreTests {
    static let dir: String = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-sync-\(UUID().uuidString)").path
        setenv("MEMORYNOTES_DIR", dir, 1)
        return dir
    }()

    init() throws {
        _ = Self.dir
        try #require(NoteStore.root.path == Self.dir, "would touch the real notes database")
    }

    func remote(_ id: String, _ text: String, at: Double, deleted: Double? = nil) -> NoteStore.CloudNote {
        .init(id: id, kind: "url", target: "example.com", label: "", body_md: text, created_at: 1, updated_at: at, deleted_at: deleted)
    }

    @Test func localEditsAreDirtyUntilPushed() throws {
        let id = UUID().uuidString
        try NoteStore.save(Note(id: id, kind: .url, target: "example.com", label: "", text: "a", createdAt: 1, updatedAt: 10))
        let dirty = NoteStore.dirtyNotes().filter { $0.id == id }
        #expect(dirty.map(\.body_md) == ["a"])
        #expect(NoteStore.dirtySnapshots().contains { $0.note_id == id })
        // Edited again before the push finished: stays dirty.
        try NoteStore.save(Note(id: id, kind: .url, target: "example.com", label: "", text: "b", createdAt: 1, updatedAt: 11))
        try NoteStore.markPushed(notes: dirty)
        #expect(NoteStore.dirtyNotes().contains { $0.id == id })
        try NoteStore.markPushed(notes: NoteStore.dirtyNotes().filter { $0.id == id })
        #expect(!NoteStore.dirtyNotes().contains { $0.id == id })
    }

    @Test func newerWinsAndDeletesStick() throws {
        let id = UUID().uuidString
        try NoteStore.applyRemote(notes: [remote(id, "v1", at: 10)], snapshots: [])
        #expect(NoteStore.loadAll().first { $0.id == id }?.text == "v1")
        #expect(!NoteStore.dirtyNotes().contains { $0.id == id }, "pulled rows aren't pushed back")
        try NoteStore.applyRemote(notes: [remote(id, "old", at: 5)], snapshots: [])
        #expect(NoteStore.loadAll().first { $0.id == id }?.text == "v1")
        try NoteStore.applyRemote(notes: [remote(id, "v2", at: 20)], snapshots: [])
        #expect(NoteStore.loadAll().first { $0.id == id }?.text == "v2")
        // Deleted on another device, even though that copy is older than ours.
        try NoteStore.applyRemote(notes: [remote(id, "x", at: 15, deleted: 15)], snapshots: [])
        #expect(!NoteStore.loadAll().contains { $0.id == id })
        try NoteStore.applyRemote(notes: [remote(id, "back", at: 30)], snapshots: [])
        #expect(!NoteStore.loadAll().contains { $0.id == id }, "a later edit can't revive it")
    }

    @Test func pinsColoursAndFoldersArriveWithTheirNotes() throws {
        let note = UUID().uuidString, folder = UUID().uuidString, missing = UUID().uuidString
        var pinned = remote(note, "x", at: 10)
        pinned.pinned = true
        pinned.color = "blue"
        pinned.folder_id = folder
        var orphan = remote(UUID().uuidString, "y", at: 10)
        orphan.folder_id = missing  // its folder hasn't arrived: lands in All Notes rather than failing
        try NoteStore.applyRemote(notes: [pinned, orphan], snapshots: [],
                                  folders: [.init(id: folder, name: "Work", updated_at: 1, deleted_at: nil)])
        let local = try #require(NoteStore.loadAll().first { $0.id == note })
        #expect(local.pinned && local.color == .blue && local.folderID == folder)
        #expect(NoteStore.loadAll().first { $0.id == orphan.id }?.folderID == nil)
        #expect(NoteStore.folders().contains { $0.id == folder && $0.name == "Work" })
        // A local pin is a change to push, without counting as an edit.
        var edited = local
        edited.pinned = false
        try NoteStore.saveMeta(edited)
        let pushed = try #require(NoteStore.dirtyNotes().first { $0.id == note })
        #expect(pushed.pinned == false && pushed.updated_at == 11)
    }

    @Test func snapshotsNeedTheirNoteAndCursorsPersist() throws {
        let id = UUID().uuidString
        let snap = NoteStore.CloudSnapshot(note_id: id, day: "2026-10-01", body_md: "s", updated_at: 3)
        try NoteStore.applyRemote(notes: [], snapshots: [snap])  // note not here yet: skipped, not an error
        try NoteStore.applyRemote(notes: [remote(id, "n", at: 3)], snapshots: [snap])
        #expect(NoteStore.loadHistory().contains { $0.note.id == id && $0.day == "2026-10-01" })
        try NoteStore.setSyncValue("cursor.notes", "42")
        #expect(NoteStore.syncValue("cursor.notes") == "42")
        try NoteStore.resetSync()
        #expect(NoteStore.syncValue("cursor.notes") == nil)
        #expect(NoteStore.dirtyNotes(limit: 10_000).contains { $0.id == id })
    }
}
