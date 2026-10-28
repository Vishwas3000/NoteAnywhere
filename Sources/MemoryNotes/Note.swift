import Foundation
import SQLite3
import notify

struct Note: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case app, url }

    var id = UUID().uuidString
    var kind: Kind
    var target: String  // bundle id for apps, "host/path" for websites
    var label: String
    var text = ""
    var createdAt = Date().timeIntervalSince1970 * 1000
    var updatedAt = Date().timeIntervalSince1970 * 1000
}

extension Note {
    /// The first line without Markdown, like the title Apple Notes shows in its list.
    var title: String { plainLines.first ?? "New Note" }
    /// What follows the title, flattened to one line.
    var preview: String { plainLines.dropFirst().prefix(4).joined(separator: " ") }
    var edited: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
    /// A note can stand alone: no app or website, stored as a website note without an address.
    var hasSource: Bool { !target.isEmpty }

    /// Obsidian-style #tags, lowercased and in order of first use: "#ML", "#project/notes". A tag needs a letter
    /// ("#2024" isn't one) and doesn't count inside code or a link's address; "# Heading" has a space, so it's no tag.
    var tags: [String] {
        var inFence = false, seen = Set<String>(), found: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            let prose = line.replacing(#/`[^`]*`|\]\([^)]*\)|<[^>]*>/#, with: " ")  // code spans, link targets, autolinks
            for match in prose.matches(of: #/(?:^|[\s(\[{,;:!?])#([\w\-/]*[^\W\d][\w\-/]*)/#) {
                let tag = String(match.1).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !tag.isEmpty, seen.insert(tag).inserted { found.append(tag) }
            }
        }
        return found
    }

    /// Lines with a date: "@2026-10-30" (what the editor writes) or Obsidian Tasks' "📅 2026-10-30". A checklist
    /// line is a task, shown done when checked. The calendar puts each on its day.
    var dates: [DatedLine] {
        var inFence = false, found: [DatedLine] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            let prose = line.replacing(#/`[^`]*`/#, with: " ")
            let days = prose.matches(of: #/(?:^|[\s(\[])(?:@|📅\s?)(\d{4}-\d{2}-\d{2})(?![\w-])/#).map { String($0.1) }
                .filter { DatedLine.isDay($0) }
            guard !days.isEmpty else { continue }
            let task = line.firstMatch(of: #/^\s*[-*+]\s+\[([ xX])\]\s/#)
            let words = Note.plain(Substring(prose.replacing(#/(?:@|📅\s?)\d{4}-\d{2}-\d{2}/#, with: "")))
                .replacing(#/\s{2,}/#, with: " ")
            for day in Set(days).sorted() {
                found.append(DatedLine(noteID: id, line: index, day: day, text: words.isEmpty ? title : words,
                                       isTask: task != nil, done: task.map { $0.1 != " " } ?? false))
            }
        }
        return found
    }

    /// True for "#project" on a note tagged #project or #project/notes, like Obsidian's tag search.
    func hasTag(_ tag: String) -> Bool { tags.contains { $0 == tag || $0.hasPrefix(tag + "/") } }

    private var plainLines: [String] {
        var inFence = false
        return text.split(separator: "\n").compactMap { line in
            if line.hasPrefix("```") { inFence.toggle(); return nil }
            let plain = inFence ? String(line).trimmingCharacters(in: .whitespaces) : Self.plain(line)
            return plain.isEmpty ? nil : plain
        }
    }

    /// One line of Markdown as plain text: no heading/list/quote/checkbox markers, emphasis, code ticks or link targets.
    static func plain(_ line: Substring) -> String {
        line.replacing(#/^\s*(#{1,6}\s+|>\s*|[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|\d+[.)]\s+)*/#, with: "")
            .replacing(#/^\s*(-{3,}|\*{3,}|_{3,}|\|?[\s:|-]+\|[\s:|-]*)\s*$/#, with: "")  // rules, table separators
            .replacing(#/!?\[([^\]]*)\]\([^)]*\)/#) { $0.1 }
            .replacing(#/\*\*|__|~~|`/#, with: "")
            .replacing(#/\*(\S|\S[^*]*\S)\*/#) { $0.1 }  // *italic*, but not "2 * 3"
            .replacing(#/\s*\|\s*/#, with: "  ")
            .trimmingCharacters(in: .whitespaces)
    }
}

extension Note {
    /// A website note's target for a page, the way the browser extension makes it: "github.com/vercel/next.js",
    /// without scheme, "www.", query, hash or trailing "/". Empty for addresses that aren't web pages.
    static func pageTarget(_ url: URL) -> String {
        guard ["http", "https"].contains(url.scheme?.lowercased()),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.percentEncodedHost, !host.isEmpty else { return "" }
        var path = parts.percentEncodedPath  // still encoded, like location.pathname
        if path.hasSuffix("/") { path.removeLast() }
        return host.lowercased().replacing(#/^www\./#, with: "") + (parts.port.map { ":\($0)" } ?? "") + path
    }
}

/// One dated line of a note: a task due that day, or anything else written for it.
struct DatedLine: Hashable, Identifiable {
    let noteID: String
    let line: Int  // index in the note's text, so the calendar can tick the task
    let day: String  // "yyyy-MM-dd"
    let text: String
    let isTask: Bool
    let done: Bool
    var id: String { "\(noteID)/\(line)/\(day)" }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()

    /// "2026-02-30" looks like a date but isn't one.
    static func isDay(_ day: String) -> Bool { parser.date(from: day).map { parser.string(from: $0) == day } ?? false }
}

/// Apple Intelligence's title and tags for one version of a note.
struct Suggestion: Hashable {
    let noteID: String
    let updatedAt: Double
    let title: String
    let tags: [String]
}

/// A note as it was at the end of one local day (its last save that day).
struct Snapshot: Identifiable, Hashable {
    let day: String  // "yyyy-MM-dd", local time
    let note: Note
    var id: String { note.id + "/" + day }
}

/// One SQLite database shared by the app and the short-lived browser host process (WAL lets both write).
/// Deletes are soft (deleted_at) so a future sync can propagate them; every read skips deleted notes.
enum NoteStore {
    struct BadID: Error {}
    struct SQLError: Error, CustomStringConvertible { let description: String }

    /// Posted (Darwin notify, crosses processes) after every committed note change.
    static let changed = "com.memorynotes.changed"
    static let embeddingModel = "sentence-transformers/all-MiniLM-L6-v2"

    static let appGroup = "group.com.memorynotes"
    static let root: URL = {
        #if os(iOS)
        // Shared with the Share and Safari extensions.
        let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        #else
        let shared: URL? = nil
        #endif
        let root = ProcessInfo.processInfo.environment["MEMORYNOTES_DIR"].map { URL(fileURLWithPath: $0) }
            ?? shared?.appendingPathComponent("MemoryNotes")
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MemoryNotes")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    // MARK: Notes

    static func loadAll() -> [Note] {
        (try? query("""
            SELECT id, kind, target, title, body_md, created_at, updated_at FROM notes
            WHERE deleted_at IS NULL ORDER BY created_at
            """, [], note)) ?? []
    }

    /// Website notes for a page and every page under it, never its parents.
    /// "github.com/" shows the whole site; "github.com/vercel" shows github.com/vercel/next.js but not github.com.
    static func notes(under url: String) -> [Note] {
        var page = url
        while page.hasSuffix("/") { page.removeLast() }
        // "0" sorts right after "/", so [page/, page0) is exactly the targets under this page, on the (kind, target) index.
        return (try? query("""
            SELECT id, kind, target, title, body_md, created_at, updated_at FROM notes
            WHERE deleted_at IS NULL AND kind = 'url' AND (target = ?1 OR (target >= ?2 AND target < ?3))
            ORDER BY created_at
            """, [page, page + "/", page + "0"], note)) ?? []
    }

    static func loadHistory() -> [Snapshot] {
        (try? query("""
            SELECT n.id, n.kind, n.target, n.title, s.body_md, n.created_at, s.updated_at, s.day
            FROM snapshots s JOIN notes n ON n.id = s.note_id
            WHERE n.deleted_at IS NULL ORDER BY s.updated_at
            """, []) { Snapshot(day: text($0, 7), note: note($0)) }) ?? []
    }

    /// Upserts the note and that day's snapshot together. Saving a deleted note, or one whose kind differs
    /// (e.g. the browser reusing an app note's id), changes nothing.
    static func save(_ note: Note) throws {
        try validate(note.id)
        try transaction {
            try run("""
                INSERT INTO notes (id, kind, target, title, body_md, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET target = excluded.target, title = excluded.title,
                    body_md = excluded.body_md, updated_at = excluded.updated_at, dirty = 1
                WHERE notes.deleted_at IS NULL AND notes.kind = excluded.kind
                """, [note.id, note.kind.rawValue, note.target, note.label, note.text, note.createdAt, note.updatedAt])
            guard sqlite3_changes(try db()) > 0 else { return }
            try run("""
                INSERT INTO snapshots (note_id, day, body_md, updated_at) VALUES (?, ?, ?, ?)
                ON CONFLICT (note_id, day) DO UPDATE SET body_md = excluded.body_md, updated_at = excluded.updated_at, dirty = 1
                """, [note.id, day(note.updatedAt), note.text, note.updatedAt])
        }
        notify_post(changed)
    }

    static func delete(_ id: String) throws {
        try validate(id)
        let now = Date().timeIntervalSince1970 * 1000
        try transaction { try run("UPDATE notes SET deleted_at = ?, updated_at = ?, dirty = 1 WHERE id = ? AND deleted_at IS NULL", [now, now, id]) }
        notify_post(changed)
    }

    // MARK: Cloud sync (rows as the server stores them; see CloudSync)

    struct CloudNote: Codable, Equatable {
        var id: String, kind: String, target: String, label: String, body_md: String
        var created_at: Double, updated_at: Double, deleted_at: Double?
        var seq: Int?
    }

    struct CloudSnapshot: Codable, Equatable {
        var note_id: String, day: String, body_md: String, updated_at: Double
        var seq: Int?
    }

    static func dirtyNotes(limit: Int = 200) -> [CloudNote] {
        (try? query("""
            SELECT id, kind, target, title, body_md, created_at, updated_at, deleted_at FROM notes WHERE dirty = 1 LIMIT ?
            """, [limit]) { row in
            CloudNote(id: text(row, 0), kind: text(row, 1), target: text(row, 2), label: text(row, 3), body_md: text(row, 4),
                      created_at: sqlite3_column_double(row, 5), updated_at: sqlite3_column_double(row, 6),
                      deleted_at: sqlite3_column_type(row, 7) == SQLITE_NULL ? nil : sqlite3_column_double(row, 7))
        }) ?? []
    }

    static func dirtySnapshots(limit: Int = 500) -> [CloudSnapshot] {
        (try? query("SELECT note_id, day, body_md, updated_at FROM snapshots WHERE dirty = 1 LIMIT ?", [limit]) { row in
            CloudSnapshot(note_id: text(row, 0), day: text(row, 1), body_md: text(row, 2), updated_at: sqlite3_column_double(row, 3))
        }) ?? []
    }

    /// After a push: clean only rows nobody edited meanwhile.
    static func markPushed(notes: [CloudNote] = [], snapshots: [CloudSnapshot] = []) throws {
        try transaction {
            for n in notes { try run("UPDATE notes SET dirty = 0 WHERE id = ? AND updated_at = ?", [n.id, n.updated_at]) }
            for s in snapshots {
                try run("UPDATE snapshots SET dirty = 0 WHERE note_id = ? AND day = ? AND updated_at = ?", [s.note_id, s.day, s.updated_at])
            }
        }
    }

    /// Pulled rows: the newer edit wins and deletes stick, as on the server. Posts `changed` when anything changed.
    static func applyRemote(notes: [CloudNote], snapshots: [CloudSnapshot]) throws {
        var changes: Int32 = 0
        try transaction {
            let handle = try db()
            let before = sqlite3_total_changes(handle)
            for n in notes where (try? validate(n.id)) != nil && (n.kind == "app" || n.kind == "url") {
                let deleted: Any = n.deleted_at ?? NSNull()
                try run("""
                    INSERT INTO notes (id, kind, target, title, body_md, created_at, updated_at, deleted_at, dirty)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
                    ON CONFLICT (id) DO UPDATE SET target = excluded.target, title = excluded.title, body_md = excluded.body_md,
                        updated_at = excluded.updated_at, deleted_at = coalesce(notes.deleted_at, excluded.deleted_at), dirty = 0
                    WHERE excluded.updated_at > notes.updated_at
                    """, [n.id, n.kind, n.target, n.label, n.body_md, n.created_at, n.updated_at, deleted])
                if let at = n.deleted_at {  // deleted elsewhere, even if edited here later
                    try run("UPDATE notes SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL", [at, n.id])
                }
            }
            for s in snapshots {
                try run("""
                    INSERT INTO snapshots (note_id, day, body_md, updated_at, dirty)
                    SELECT ?1, ?2, ?3, ?4, 0 WHERE EXISTS (SELECT 1 FROM notes WHERE id = ?1)
                    ON CONFLICT (note_id, day) DO UPDATE SET body_md = excluded.body_md, updated_at = excluded.updated_at, dirty = 0
                    WHERE excluded.updated_at > snapshots.updated_at
                    """, [s.note_id, s.day, s.body_md, s.updated_at])
            }
            changes = sqlite3_total_changes(handle) - before
        }
        if changes > 0 { notify_post(changed) }
    }

    static func syncValue(_ key: String) -> String? {
        (try? query("SELECT value FROM sync_state WHERE key = ?", [key]) { text($0, 0) })?.first
    }

    static func setSyncValue(_ key: String, _ value: String?) throws {
        try transaction {
            if let value { try run("INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?)", [key, value]) }
            else { try run("DELETE FROM sync_state WHERE key = ?", [key]) }
        }
    }

    /// Signing in to a different account: everything here goes up to it, and its notes come down from the start.
    static func resetSync() throws {
        try transaction {
            try run("UPDATE notes SET dirty = 1", [])
            try run("UPDATE snapshots SET dirty = 1", [])
            try run("DELETE FROM sync_state WHERE key LIKE 'cursor.%'", [])
        }
    }

    // MARK: Embeddings and icons (derived caches: no change notification)

    static func vectors() -> [String: (updatedAt: Double, vector: [Float])] {
        let rows = (try? query("""
            SELECT e.note_id, e.updated_at, e.vector FROM embeddings e JOIN notes n ON n.id = e.note_id
            WHERE n.deleted_at IS NULL AND e.model = ?
            """, [embeddingModel]) { row in
            (text(row, 0), sqlite3_column_double(row, 1), floats(blob(row, 2)))
        }) ?? []
        return Dictionary(rows.map { ($0.0, (updatedAt: $0.1, vector: $0.2)) }, uniquingKeysWith: { a, _ in a })
    }

    static func saveVector(_ id: String, updatedAt: Double, vector: [Float]) throws {
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }  // Float32, little-endian on every Mac
        try transaction {
            try run("""
                INSERT INTO embeddings (note_id, model, updated_at, vector) VALUES (?, ?, ?, ?)
                ON CONFLICT (note_id) DO UPDATE SET model = excluded.model, updated_at = excluded.updated_at, vector = excluded.vector
                """, [id, embeddingModel, updatedAt, data])
        }
    }

    /// Suggested title and tags, keyed by note id, with the note version they were made from.
    static func suggestions() -> [String: Suggestion] {
        let rows = (try? query("""
            SELECT s.note_id, s.updated_at, s.title, s.tags_json FROM suggestions s JOIN notes n ON n.id = s.note_id
            WHERE n.deleted_at IS NULL
            """, []) { row in
            Suggestion(noteID: text(row, 0), updatedAt: sqlite3_column_double(row, 1), title: text(row, 2),
                       tags: (try? JSONDecoder().decode([String].self, from: Data(text(row, 3).utf8))) ?? [])
        }) ?? []
        return Dictionary(rows.map { ($0.noteID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static func saveSuggestion(_ s: Suggestion) throws {
        let tags = String(data: try JSONEncoder().encode(s.tags), encoding: .utf8) ?? "[]"
        try transaction {
            try run("INSERT OR REPLACE INTO suggestions (note_id, updated_at, title, tags_json) VALUES (?, ?, ?, ?)",
                    [s.noteID, s.updatedAt, s.title, tags])
        }
    }

    static func icon(_ key: String) -> Data? {
        (try? query("SELECT png FROM icons WHERE key = ?", [key]) { blob($0, 0) })?.first
    }

    static func saveIcon(_ key: String, png: Data) {
        try? transaction {
            try run("INSERT OR REPLACE INTO icons (key, png, fetched_at) VALUES (?, ?, ?)", [key, png, Date().timeIntervalSince1970 * 1000])
        }
    }

    static func day(_ ms: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    // ids come from the browser too; only allow UUID characters.
    private static func validate(_ id: String) throws {
        guard !id.isEmpty, id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { throw BadID() }
    }

    // MARK: SQLite

    private static let lock = NSRecursiveLock()  // one connection shared by the main thread and the search actor
    private static let connection: Result<OpaquePointer, Error> = Result { try open() }
    private static func db() throws -> OpaquePointer { try connection.get() }

    private static func open() throws -> OpaquePointer {
        var handle: OpaquePointer?
        let path = root.appendingPathComponent("memorynotes.sqlite").path
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else { throw SQLError(description: "can't open \(path)") }
        sqlite3_busy_timeout(handle, 5000)  // the app and the browser host may write at the same moment
        for pragma in ["PRAGMA journal_mode = WAL", "PRAGMA foreign_keys = ON"] {
            sqlite3_exec(handle, pragma, nil, nil, nil)
        }
        try migrate(handle)
        return handle
    }

    private static let schemaV1 = """
        CREATE TABLE folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT REFERENCES folders (id) ON DELETE CASCADE);
        CREATE TABLE notes (
            id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK (kind IN ('app', 'url')), target TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '', body_md TEXT NOT NULL DEFAULT '',
            folder_id TEXT REFERENCES folders (id) ON DELETE SET NULL, pinned INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL, updated_at REAL NOT NULL, deleted_at REAL);
        CREATE INDEX notes_kind_target ON notes (kind, target);
        CREATE TABLE snapshots (note_id TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE, day TEXT NOT NULL,
            body_md TEXT NOT NULL, updated_at REAL NOT NULL, PRIMARY KEY (note_id, day));
        CREATE TABLE embeddings (note_id TEXT PRIMARY KEY REFERENCES notes (id) ON DELETE CASCADE, model TEXT NOT NULL,
            updated_at REAL NOT NULL, vector BLOB NOT NULL);
        CREATE TABLE tags (note_id TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE, tag TEXT NOT NULL, PRIMARY KEY (note_id, tag));
        CREATE TABLE links (from_note TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE,
            to_note TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE, PRIMARY KEY (from_note, to_note));
        CREATE TABLE attachments (id TEXT PRIMARY KEY, note_id TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE,
            kind TEXT NOT NULL, path TEXT NOT NULL, meta_json TEXT);
        CREATE TABLE icons (key TEXT PRIMARY KEY, png BLOB NOT NULL, fetched_at REAL NOT NULL);
        """

    /// Schema version lives in PRAGMA user_version. BEGIN IMMEDIATE + re-check, since the app and host may start together.
    private static func migrate(_ handle: OpaquePointer) throws {
        var imported = false
        try exec(handle, "BEGIN IMMEDIATE")
        do {
            if try userVersion(handle) < 1 {
                try exec(handle, schemaV1)
                imported = try importJSON(handle)
                try exec(handle, "PRAGMA user_version = 1")
            }
            if try userVersion(handle) < 2 {
                // Apple Intelligence's suggested title and tags per note version; kept apart from the user's own #tags.
                try exec(handle, """
                    CREATE TABLE suggestions (note_id TEXT PRIMARY KEY REFERENCES notes (id) ON DELETE CASCADE,
                        updated_at REAL NOT NULL, title TEXT NOT NULL, tags_json TEXT NOT NULL);
                    PRAGMA user_version = 2;
                    """)
            }
            if try userVersion(handle) < 3 {
                // Cloud sync (D31): dirty rows changed here and not yet pushed; sync_state keeps pull cursors.
                try exec(handle, """
                    ALTER TABLE notes ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1;
                    ALTER TABLE snapshots ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1;
                    CREATE INDEX notes_dirty ON notes (dirty) WHERE dirty = 1;
                    CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    PRAGMA user_version = 3;
                    """)
            }
            try exec(handle, "COMMIT")
        } catch {
            try? exec(handle, "ROLLBACK")
            throw error
        }
        if imported {
            // Keep the old files (renamed) rather than deleting the user's data.
            for name in ["notes", "history", "embeddings.json"] {
                let old = root.appendingPathComponent(name)
                try? FileManager.default.moveItem(at: old, to: old.appendingPathExtension("imported"))
            }
        }
    }

    /// One-time import of the pre-SQLite layout: notes/<id>.json, history/<id>/<day>.json, embeddings.json.
    private static func importJSON(_ handle: OpaquePointer) throws -> Bool {
        let fm = FileManager.default
        let notesDir = root.appendingPathComponent("notes")
        let files = (try? fm.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil)) ?? []
        let notes = files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Note.self, from: Data(contentsOf: $0)) }
            .filter { (try? validate($0.id)) != nil }
        guard !notes.isEmpty else { return false }
        for n in notes {
            try run(handle, "INSERT OR IGNORE INTO notes (id, kind, target, title, body_md, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    [n.id, n.kind.rawValue, n.target, n.label, n.text, n.createdAt, n.updatedAt])
            let history = root.appendingPathComponent("history").appendingPathComponent(n.id)
            for file in (try? fm.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
                guard let s = try? JSONDecoder().decode(Note.self, from: Data(contentsOf: file)) else { continue }
                try run(handle, "INSERT OR IGNORE INTO snapshots (note_id, day, body_md, updated_at) VALUES (?, ?, ?, ?)",
                        [n.id, file.deletingPathExtension().lastPathComponent, s.text, s.updatedAt])
            }
        }
        struct OldVector: Decodable { let updatedAt: Double; let vector: [Float] }
        let ids = Set(notes.map(\.id))
        if let data = try? Data(contentsOf: root.appendingPathComponent("embeddings.json")),
           let old = try? JSONDecoder().decode([String: OldVector].self, from: data) {
            for (id, v) in old where ids.contains(id) {
                try run(handle, "INSERT OR IGNORE INTO embeddings (note_id, model, updated_at, vector) VALUES (?, ?, ?, ?)",
                        [id, embeddingModel, v.updatedAt, v.vector.withUnsafeBufferPointer { Data(buffer: $0) }])
            }
        }
        return true
    }

    private static func userVersion(_ handle: OpaquePointer) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { throw error(handle) }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private static func transaction(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        let handle = try db()
        try exec(handle, "BEGIN IMMEDIATE")
        do {
            try body()
            try exec(handle, "COMMIT")
        } catch {
            try? exec(handle, "ROLLBACK")
            throw error
        }
    }

    private static func exec(_ handle: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error(handle) }
    }

    private static func run(_ sql: String, _ args: [Any]) throws { try run(try db(), sql, args) }

    private static func run(_ handle: OpaquePointer, _ sql: String, _ args: [Any]) throws {
        let stmt = try prepare(handle, sql, args)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error(handle) }
    }

    private static func query<T>(_ sql: String, _ args: [Any], _ row: (OpaquePointer) -> T) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        let handle = try db()
        let stmt = try prepare(handle, sql, args)
        defer { sqlite3_finalize(stmt) }
        var rows: [T] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: rows.append(row(stmt))
            case SQLITE_DONE: return rows
            default: throw error(handle)
            }
        }
    }

    private static func prepare(_ handle: OpaquePointer, _ sql: String, _ args: [Any]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error(handle) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)  // SQLite copies the value
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case let s as String: sqlite3_bind_text(stmt, index, s, -1, transient)
            case let d as Double: sqlite3_bind_double(stmt, index, d)
            case let i as Int: sqlite3_bind_int64(stmt, index, Int64(i))
            case let data as Data: _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), transient) }
            case is NSNull: sqlite3_bind_null(stmt, index)
            default: sqlite3_finalize(stmt); throw SQLError(description: "unsupported bind \(type(of: arg))")
            }
        }
        return stmt
    }

    private static func error(_ handle: OpaquePointer) -> SQLError {
        SQLError(description: String(cString: sqlite3_errmsg(handle)))
    }

    private static func note(_ row: OpaquePointer) -> Note {
        Note(id: text(row, 0), kind: Note.Kind(rawValue: text(row, 1)) ?? .url, target: text(row, 2), label: text(row, 3),
             text: text(row, 4), createdAt: sqlite3_column_double(row, 5), updatedAt: sqlite3_column_double(row, 6))
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }

    private static func blob(_ row: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(row, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column)))
    }

    private static func floats(_ data: Data) -> [Float] {
        var out = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }  // copy: blob bytes needn't be Float-aligned
        return out
    }
}
