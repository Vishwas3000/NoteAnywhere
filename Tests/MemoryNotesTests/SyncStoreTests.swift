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

    /// Right-click → Color in the calendar is a text edit: it must reach the database (it once only lived in memory).
    @Test func eventColourIsSaved() throws {
        let model = NotesModel.shared
        let note = model.add(kind: .app, target: "demo.app", label: "Demo", text: "Dentist @2026-11-05 and gym @2026-11-06")
        let gym = try #require(model.notes.first { $0.id == note.id }?.dates.first { $0.day == "2026-11-06" })
        model.setColor(gym, .purple)
        #expect(NoteStore.loadAll().first { $0.id == note.id }?.text == "Dentist @2026-11-05 and gym @2026-11-06{purple}")
        model.reload()  // what a change notification does: the colour stays
        #expect(model.notes.first { $0.id == note.id }?.dates.first { $0.day == "2026-11-06" }?.color == .purple)
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
        pinned.starred = true
        pinned.color = "blue"
        pinned.folder_id = folder
        var orphan = remote(UUID().uuidString, "y", at: 10)
        orphan.folder_id = missing  // its folder hasn't arrived: lands in All Notes rather than failing
        try NoteStore.applyRemote(notes: [pinned, orphan], snapshots: [],
                                  folders: [.init(id: folder, name: "Work", updated_at: 1, deleted_at: nil)])
        let local = try #require(NoteStore.loadAll().first { $0.id == note })
        #expect(local.pinned && local.starred && local.color == .blue && local.folderID == folder)
        #expect(NoteStore.loadAll().first { $0.id == orphan.id }?.folderID == nil)
        #expect(NoteStore.folders().contains { $0.id == folder && $0.name == "Work" })
        // A local pin is a change to push, without counting as an edit.
        var edited = local
        edited.pinned = false
        edited.starred = false
        try NoteStore.saveMeta(edited)
        let pushed = try #require(NoteStore.dirtyNotes().first { $0.id == note })
        #expect(pushed.pinned == false && pushed.starred == false && pushed.updated_at == 11)
        #expect(NoteStore.loadAll().first { $0.id == note }?.starred == false)
    }

    @Test func lockingLeavesNoReadableCopy() throws {
        let id = UUID().uuidString
        try NoteStore.save(Note(id: id, kind: .url, target: "bank.example", label: "", text: "pin 1234", createdAt: 1, updatedAt: 10))
        try NoteStore.saveVector(id, updatedAt: 10, vector: [1, 0])
        let sealed = try NoteLock.seal("pin 1234", password: "pw")
        try NoteStore.setLocked(id, text: sealed, locked: true)
        let note = try #require(NoteStore.loadAll().first { $0.id == id })
        #expect(note.locked && note.text == sealed && note.title == "Locked Note" && note.tags.isEmpty)
        #expect(NoteStore.loadHistory().filter { $0.note.id == id }.allSatisfy { !$0.note.text.contains("1234") })
        #expect(NoteStore.vectors()[id] == nil)
        #expect(!NoteStore.notes(under: "bank.example").contains { $0.id == id }, "the browser never sees it")
        // A browser tab that loaded the note before it was locked can't write readable text over it.
        try NoteStore.save(Note(id: id, kind: .url, target: "bank.example", label: "", text: "pin 1234", createdAt: 1, updatedAt: 99_999_999_999_999))
        #expect(NoteStore.loadAll().first { $0.id == id }?.text == sealed)
    }

    @Test func imagesSyncAsFilesPlusRows() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let id = try NoteStore.saveImage(png, type: "image/png")
        let dirty = NoteStore.dirtyImages(limit: 10_000).filter { $0.id == id }
        #expect(dirty.map(\.type) == ["image/png"])
        #expect(!NoteStore.wantsImage(dirty[0]), "this device already has it")
        try NoteStore.markPushed(images: dirty)
        #expect(!NoteStore.dirtyImages(limit: 10_000).contains { $0.id == id })

        // From another device: wanted until its bytes are written, then shows like a local one and isn't pushed back.
        let remote = NoteStore.CloudImage(id: UUID().uuidString.lowercased(), type: "image/jpeg", created_at: 5)
        #expect(NoteStore.wantsImage(remote))
        try NoteStore.saveRemoteImage(remote, data: Data([0xFF, 0xD8, 9]))
        #expect(NoteStore.image(remote.id)?.data == Data([0xFF, 0xD8, 9]) && NoteStore.image(remote.id)?.type == "image/jpeg")
        #expect(!NoteStore.wantsImage(remote))
        #expect(!NoteStore.dirtyImages(limit: 10_000).contains { $0.id == remote.id })

        // Malformed rows are skipped, and bytes that aren't an image notes hold are refused.
        #expect(!NoteStore.wantsImage(.init(id: "../notes", type: "image/png", created_at: 1)))
        #expect(!NoteStore.wantsImage(.init(id: UUID().uuidString, type: "text/html", created_at: 1)))
        let big = NoteStore.CloudImage(id: UUID().uuidString, type: "image/png", created_at: 1)
        #expect(throws: NoteStore.ImageError.self) { try NoteStore.saveRemoteImage(big, data: Data(count: NoteStore.maxImageBytes + 1)) }
        #expect(NoteStore.image(big.id) == nil)

        // Another account: every image goes up again.
        try NoteStore.resetSync()
        #expect(Set(NoteStore.dirtyImages(limit: 10_000).map(\.id)).isSuperset(of: [id, remote.id]))
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

    /// D77: "#note" finds #noteanywhere while you type; the exact tag (and its nested ones) still comes first.
    /// Here, not with the other tag tests, because SearchIndex opens the database it finds when it starts.
    @Test func tagSearchMatchesThePartTyped() async {
        let partial = Note(kind: .url, target: "", label: "", text: "Bugs\n#noteanywhere", updatedAt: 3)
        let exact = Note(kind: .url, target: "", label: "", text: "Reading list #note", updatedAt: 1)
        let nested = Note(kind: .url, target: "", label: "", text: "#note/ideas", updatedAt: 2)
        let other = Note(kind: .url, target: "", label: "", text: "#flam #notnote", updatedAt: 4)
        let hits = await SearchIndex.shared.search("#note", in: [partial, exact, nested, other]).map(\.note.id)
        #expect(hits == [nested.id, exact.id, partial.id])
        #expect(await SearchIndex.shared.search("#NOTEANY", in: [partial, other]).map(\.note.id) == [partial.id])
    }
}
