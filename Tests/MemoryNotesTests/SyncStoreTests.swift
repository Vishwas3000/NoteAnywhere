import Foundation
import SQLite3
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

    /// D76: the server's uuid columns answer in lowercase. The Mac made uppercase ids, so every synced note came back
    /// as a second copy. A note made here must come back as itself.
    @Test func aNotePulledBackStaysOneNote() throws {
        let note = NotesModel.shared.add(kind: .url, target: "example.com", label: "", text: "x")
        #expect(note.id == note.id.lowercased())
        try NoteStore.applyRemote(notes: [remote(note.id.lowercased(), "x", at: note.updatedAt + 1)], snapshots: [])
        #expect(NoteStore.loadAll().filter { $0.id.lowercased() == note.id.lowercased() }.count == 1)
    }

    /// D76 repairs stores that synced before it: each uppercase/lowercase pair becomes one note (the newer edit wins),
    /// every snapshot day and tag survives, folders merge too, and all ids end up lowercase.
    @Test func version7MergesCaseDuplicates() throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(Self.dir + "/v7-\(UUID().uuidString).sqlite", &db) == SQLITE_OK)
        let handle = try #require(db)
        defer { sqlite3_close(handle) }
        sqlite3_exec(handle, "PRAGMA foreign_keys = ON", nil, nil, nil)
        try NoteStore.migrate(handle)  // an empty store at the current version
        let a = "AAAAAAAA-1111-4111-8111-111111111111", b = "BBBBBBBB-2222-4222-8222-222222222222"
        let c = "CCCCCCCC-3333-4333-8333-333333333333", f = "FFFFFFFF-4444-4444-8444-444444444444"
        let (la, lb, lc, lf) = (a.lowercased(), b.lowercased(), c.lowercased(), f.lowercased())
        // a: edited here after a sync pulled its twin, so the uppercase copy is newer; b: the pulled copy is newer;
        // c: never synced, so it has no twin.
        try #require(sqlite3_exec(handle, """
            INSERT INTO folders (id, name, updated_at, dirty) VALUES ('\(f)', 'Work', 1, 0), ('\(lf)', 'Work', 1, 0);
            INSERT INTO notes (id, kind, target, body_md, folder_id, created_at, updated_at, dirty) VALUES
                ('\(a)', 'url', 'x.com', 'a new', '\(f)', 1, 20, 1), ('\(la)', 'url', 'x.com', 'a old', '\(lf)', 1, 10, 0),
                ('\(b)', 'url', 'x.com', 'b old', NULL, 1, 10, 0), ('\(lb)', 'url', 'x.com', 'b new', NULL, 1, 20, 0),
                ('\(c)', 'url', 'x.com', 'c', '\(f)', 1, 10, 1);
            INSERT INTO snapshots (note_id, day, body_md, updated_at, dirty) VALUES
                ('\(a)', '2026-11-01', 'only here', 5, 0), ('\(a)', '2026-11-02', 'a new', 20, 1),
                ('\(la)', '2026-11-02', 'a old', 10, 0), ('\(c)', '2026-11-01', 'c', 10, 1);
            INSERT INTO tags (note_id, tag) VALUES ('\(a)', 'work'), ('\(la)', 'work');
            PRAGMA user_version = 6;
            """, nil, nil, nil) == SQLITE_OK)
        try NoteStore.migrate(handle)
        func rows(_ sql: String) -> [String] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return ["can't run: \(sql)"] }
            defer { sqlite3_finalize(statement) }
            var out: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW { out.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "NULL") }
            return out
        }
        #expect(rows("SELECT id || ' ' || body_md || ' ' || dirty || ' ' || ifnull(folder_id, '-') FROM notes ORDER BY id")
                == ["\(la) a new 1 \(lf)", "\(lb) b new 0 -", "\(lc) c 1 \(lf)"])
        #expect(rows("SELECT note_id || ' ' || day || ' ' || body_md FROM snapshots ORDER BY note_id, day")
                == ["\(la) 2026-11-01 only here", "\(la) 2026-11-02 a new", "\(lc) 2026-11-01 c"])
        #expect(rows("SELECT note_id FROM tags") == [la])
        #expect(rows("SELECT id FROM folders") == [lf])
        #expect(rows("PRAGMA foreign_key_check").isEmpty)
        #expect(rows("PRAGMA user_version") == ["7"])
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
