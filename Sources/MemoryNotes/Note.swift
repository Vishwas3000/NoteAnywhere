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

/// One JSON file per note, so the app and the browser host can write concurrently without clobbering each other.
enum NoteStore {
    struct BadID: Error {}

    static let dir: URL = {
        let dir = ProcessInfo.processInfo.environment["MEMORYNOTES_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MemoryNotes/notes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func loadAll() -> [Note] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Note.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    static func save(_ note: Note) throws {
        try JSONEncoder().encode(note).write(to: file(note.id), options: .atomic)
    }

    static func delete(_ id: String) throws {
        try? FileManager.default.removeItem(at: file(id))
    }

    // ids come from the browser too; only allow UUID characters so an id can't escape the folder.
    private static func file(_ id: String) throws -> URL {
        guard !id.isEmpty, id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { throw BadID() }
        return dir.appendingPathComponent(id + ".json")
    }
}
