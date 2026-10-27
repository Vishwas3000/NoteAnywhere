import Foundation

/// Chrome Native Messaging host: each message is a 4-byte little-endian length followed by UTF-8 JSON.
/// Chrome starts this process on demand, so the extension works even when the app isn't open.
enum NativeHost {
    struct Request: Decodable {
        let op: String
        var url: String?
        var note: Note?
        var id: String?
        var query: String?
    }

    struct Reply: Encodable {
        var ok = true
        var notes: [Note]?
        var note: Note?
        var results: [SearchIndex.Hit]?
        var error: String?
    }

    static func run() -> Never {
        let stdin = FileHandle.standardInput
        while true {
            let header = stdin.readData(ofLength: 4)
            guard header.count == 4 else { exit(0) }  // Chrome closed the pipe
            let length = UInt32(littleEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            let reply = handle(stdin.readData(ofLength: Int(length)))
            // shortcut: Chrome caps host replies at 1 MB; fine for text notes on one page, paginate if that's ever hit.
            let body = (try? JSONEncoder().encode(reply)) ?? Data(#"{"ok":false,"error":"encode failed"}"#.utf8)
            var size = UInt32(body.count).littleEndian
            FileHandle.standardOutput.write(Data(bytes: &size, count: 4) + body)
        }
    }

    /// The host loop is synchronous; run one async call to completion.
    private static func blocking<T>(_ work: @escaping () async -> T) -> T {
        var result: T?
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            result = await work()
            done.signal()
        }
        done.wait()
        return result!
    }

    static func handle(_ data: Data) -> Reply {
        do {
            let req = try JSONDecoder().decode(Request.self, from: data)
            switch req.op {
            case "list":
                let url = req.url ?? ""
                return Reply(notes: NoteStore.loadAll().filter { $0.matches(url: url) })
            case "save":
                // The browser may only write website notes, never app notes.
                guard var note = req.note, note.kind == .url, !note.target.isEmpty else {
                    return Reply(ok: false, error: "save needs a website note with a target")
                }
                note.updatedAt = max(note.updatedAt, Date().timeIntervalSince1970 * 1000)
                try NoteStore.save(note)
                return Reply(note: note)
            case "search":
                let query = req.query ?? ""
                return Reply(results: blocking { await SearchIndex.shared.search(query, in: NoteStore.loadAll()) })
            case "delete":
                try NoteStore.delete(req.id ?? "")
                return Reply()
            default:
                return Reply(ok: false, error: "unknown op \(req.op)")
            }
        } catch {
            return Reply(ok: false, error: "\(error)")
        }
    }
}
