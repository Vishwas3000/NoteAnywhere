import Foundation

struct Note: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case app, url }

    var id = UUID().uuidString
    var kind: Kind
    var target: String  // bundle id for apps, "host/path" prefix for websites
    var label: String
    var text = ""
    var createdAt = Date().timeIntervalSince1970 * 1000
    var updatedAt = Date().timeIntervalSince1970 * 1000

    /// `url` is "host/path" without "www.". "github.com" matches the whole site, not "github.company.com".
    func matches(url: String) -> Bool {
        kind == .url && (url == target || url.hasPrefix(target.hasSuffix("/") ? target : target + "/"))
    }
}

/// A note as it was at the end of one local day (its last save that day).
struct Snapshot: Identifiable, Hashable {
    let day: String  // "yyyy-MM-dd", local time
    let note: Note
    var id: String { note.id + "/" + day }
}

/// One JSON file per note, so the app and the browser host can write concurrently without clobbering each other.
/// Every save also overwrites that day's snapshot in history/<id>/<day>.json, which the calendar reads.
enum NoteStore {
    struct BadID: Error {}

    static let root: URL = {
        let root = ProcessInfo.processInfo.environment["MEMORYNOTES_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MemoryNotes")
        for sub in ["notes", "history"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        return root
    }()
    static let dir = root.appendingPathComponent("notes")
    static let historyDir = root.appendingPathComponent("history")

    static func day(_ ms: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    static func loadAll() -> [Note] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Note.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    static func save(_ note: Note) throws {
        let data = try JSONEncoder().encode(note)
        try data.write(to: file(note.id), options: .atomic)
        let history = historyDir.appendingPathComponent(note.id)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try data.write(to: history.appendingPathComponent(day(note.updatedAt) + ".json"), options: .atomic)
    }

    /// Deleting a note also drops its history: deleted means gone from the calendar too.
    static func delete(_ id: String) throws {
        try? FileManager.default.removeItem(at: file(id))
        try? FileManager.default.removeItem(at: historyDir.appendingPathComponent(id))
    }

    static func loadHistory() -> [Snapshot] {
        let fm = FileManager.default
        let notes = (try? fm.contentsOfDirectory(at: historyDir, includingPropertiesForKeys: nil)) ?? []
        return notes.flatMap { folder in
            ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
                .compactMap { url in
                    (try? JSONDecoder().decode(Note.self, from: Data(contentsOf: url)))
                        .map { Snapshot(day: url.deletingPathExtension().lastPathComponent, note: $0) }
                }
        }
        .sorted { $0.note.updatedAt < $1.note.updatedAt }
    }

    // ids come from the browser too; only allow UUID characters so an id can't escape the folder.
    private static func file(_ id: String) throws -> URL {
        guard !id.isEmpty, id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { throw BadID() }
        return dir.appendingPathComponent(id + ".json")
    }
}
