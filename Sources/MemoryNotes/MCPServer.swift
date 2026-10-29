import Foundation

/// NoteAnywhere as an MCP server (`MemoryNotes --mcp`), so Claude, Codex or Gemini can search, read and edit notes.
/// stdio, one JSON-RPC message per line. Dual-era: the 2026-07-28 protocol (version and capabilities in each request's
/// `_meta`) and the older `initialize` handshake (2024-11-05 to 2025-11-25) that most clients still speak.
/// There is no delete tool, and a locked note's text is never read or written.
enum MCPServer {
    static let modern = ["2026-07-28"]
    static let legacy = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    struct ToolError: Error { let message: String }

    struct Tool {
        let name: String
        let description: String
        var properties: [String: Any] = [:]
        var required: [String] = []
        var readOnly = false
        var destructive = false
        let run: ([String: Any]) throws -> Any

        // Plain schemas (no unions, no additionalProperties): Gemini and Codex accept only a subset of JSON Schema.
        var spec: [String: Any] {
            var schema: [String: Any] = ["type": "object", "properties": properties]
            if !required.isEmpty { schema["required"] = required }
            return ["name": name, "description": description, "inputSchema": schema,
                    "annotations": readOnly ? ["readOnlyHint": true]
                        : ["readOnlyHint": false, "destructiveHint": destructive, "openWorldHint": false]]
        }
    }

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        // stdout carries protocol messages only: replies use a copy of it, and anything else printed (a library's
        // download progress, say) goes to stderr.
        let out = FileHandle(fileDescriptor: dup(STDOUT_FILENO))
        dup2(STDERR_FILENO, STDOUT_FILENO)
        while let line = readLine() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let reply = handle(line) else { continue }
            do { try out.write(contentsOf: reply + Data("\n".utf8)) } catch { exit(0) }
        }
        exit(0)  // the client closed stdin
    }

    /// One message in, at most one reply out (notifications get none).
    static func handle(_ line: String) -> Data? {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return error(NSNull(), -32700, "Parse error")
        }
        guard let method = message["method"] as? String else {
            return message["id"] == nil ? error(NSNull(), -32600, "Invalid request") : nil  // a response: we send no requests
        }
        guard let id = message["id"], !(id is NSNull) else { return nil }  // a notification: initialized, cancelled, …
        let params = message["params"] as? [String: Any] ?? [:]
        let meta = params["_meta"] as? [String: Any]
        let version = meta?["io.modelcontextprotocol/protocolVersion"] as? String
        if let version {  // modern: every request names its version and capabilities
            guard modern.contains(version) else {
                return error(id, -32022, "Unsupported protocol version", data: ["supported": modern + legacy, "requested": version])
            }
            guard meta?["io.modelcontextprotocol/clientCapabilities"] is [String: Any] else {
                return error(id, -32602, "Missing _meta.io.modelcontextprotocol/clientCapabilities")
            }
        } else if method == "server/discover" {
            return error(id, -32602, "Missing _meta.io.modelcontextprotocol/protocolVersion")
        }

        var result: [String: Any]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            result = ["protocolVersion": legacy.contains(asked) ? asked : legacy[0], "capabilities": ["tools": [:]],
                      "serverInfo": serverInfo, "instructions": instructions]
        case "server/discover":
            result = ["supportedVersions": modern, "capabilities": ["tools": [:]], "instructions": instructions]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": tools.map(\.spec)]
        case "tools/call":
            guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else {
                return error(id, -32602, "Unknown tool: \(params["name"] ?? "")")
            }
            result = call(tool, params["arguments"] as? [String: Any] ?? [:])
        default:
            return error(id, -32601, "Method not found: \(method)")
        }
        if version != nil {
            result["resultType"] = "complete"
            result["_meta"] = ["io.modelcontextprotocol/serverInfo": serverInfo]
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static let serverInfo: [String: Any] = [
        "name": "NoteAnywhere",
        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
    ]

    static let instructions = """
        The user's notes from NoteAnywhere, a Mac notes app. Notes are Markdown; the first line is the title. \
        Find notes with search_notes (by meaning and words, or "#tag") or list_notes; both return summaries, and \
        get_note returns the full text. Dated lines carry @YYYY-MM-DD and checklist items are "- [ ] "; list_tasks \
        and set_task_done work on them. Prefer append_to_note for additions; replace_note_text rewrites a note and \
        needs updated_at from get_note. Nothing can be deleted, and locked notes stay closed.
        """

    // MARK: Tools

    static let tools: [Tool] = [
        Tool(name: "search_notes",
             description: "Find notes by meaning and by exact words (on-device). A query of \"#tag\" lists that tag's notes. Returns summaries with a snippet; read one with get_note.",
             properties: ["query": text("What to look for"), "limit": number("Most results to return, default 10, up to 50")],
             required: ["query"], readOnly: true) { args in
            let query = try string(args, "query")
            let folders = folderNames()
            let hits = NativeHost.blocking { await SearchIndex.shared.search(query, in: NoteStore.loadAll(), limit: limit(args, 10, 50)) }
            return hits.map { hit in
                var s = summary(hit.note, folders)
                s["snippet"] = snippet(hit.note.text, query) ?? String(hit.note.preview.prefix(160))
                s["score"] = (hit.score * 100).rounded() / 100
                return s
            }
        },
        Tool(name: "list_notes",
             description: "List notes, newest edit first, as summaries. Filter by source (an app or site, e.g. \"Slack\" or \"github.com\"), #tag, folder, pinned, or edits since a date.",
             properties: ["source": text("Part of the app or site name or address"), "tag": text("A tag, with or without #"),
                          "folder": text("Folder name or id"), "pinned": ["type": "boolean", "description": "Only pinned (true) or unpinned (false) notes"],
                          "updated_since": text("YYYY-MM-DD or an ISO 8601 date-time"), "limit": number("Most notes to return, default 30, up to 200")],
             readOnly: true) { args in
            var notes = NoteStore.loadAll()
            if let source = args["source"] as? String, !source.isEmpty {
                notes = notes.filter { [$0.label, $0.target, $0.shortSource].contains { $0.localizedCaseInsensitiveContains(source) } }
            }
            if let tag = args["tag"] as? String, !tag.isEmpty {
                let tag = tag.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
                notes = notes.filter { $0.hasTag(tag) }
            }
            if let folder = args["folder"] as? String, !folder.isEmpty {
                let id = try folderID(folder)
                notes = notes.filter { $0.folderID == id }
            }
            if let pinned = args["pinned"] as? Bool { notes = notes.filter { $0.pinned == pinned } }
            if let since = args["updated_since"] as? String, !since.isEmpty {
                guard let date = parseDate(since) else { throw ToolError(message: "updated_since must be YYYY-MM-DD or ISO 8601, got \(since)") }
                notes = notes.filter { $0.updatedAt >= date.timeIntervalSince1970 * 1000 }
            }
            let folders = folderNames()
            let shown = notes.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit(args, 30, 200)).map { note in
                var s = summary(note, folders)
                if !note.preview.isEmpty { s["preview"] = String(note.preview.prefix(120)) }
                return s
            }
            return ["total": notes.count, "notes": shown]
        },
        Tool(name: "get_note",
             description: "A note's full Markdown text with its source, folder, tags, dated lines and updated_at (needed by replace_note_text).",
             properties: ["id": text("The note's id")], required: ["id"], readOnly: true) { args in
            let note = try fetch(try string(args, "id"))
            var r = summary(note, folderNames())
            r["kind"] = note.kind == .app ? "app" : note.hasSource ? "website" : "plain"
            if note.hasSource { r["target"] = note.target; r["label"] = note.label }
            r["created"] = iso(note.createdAt)
            r["updated_at"] = stamp(note)
            if !note.locked {
                r["text"] = note.text
                r["tags"] = note.tags
                r["dates"] = note.dates.map { task($0, title: nil) }
            }
            return r
        },
        Tool(name: "list_tasks",
             description: "Lines dated with @YYYY-MM-DD across all notes (checklist items are tasks), by day. Open ones only unless include_done.",
             properties: ["from": text("First day, YYYY-MM-DD"), "to": text("Last day, YYYY-MM-DD"),
                          "include_done": ["type": "boolean", "description": "Also list ticked tasks"],
                          "limit": number("Most lines to return, default 100, up to 500")],
             readOnly: true) { args in
            let from = args["from"] as? String, to = args["to"] as? String
            for day in [from, to].compactMap({ $0 }) where !DatedLine.isDay(day) {
                throw ToolError(message: "Days are YYYY-MM-DD, got \(day)")
            }
            let includeDone = args["include_done"] as? Bool ?? false
            let notes = NoteStore.loadAll()
            let titles = Dictionary(notes.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
            let items = notes.flatMap(\.dates)
                .filter { item in (from.map { item.day >= $0 } ?? true) && (to.map { item.day <= $0 } ?? true) && (includeDone || !item.done) }
                .sorted { ($0.day, $0.noteID, $0.line) < ($1.day, $1.noteID, $1.line) }
            return ["total": items.count, "lines": items.prefix(limit(args, 100, 500)).map { task($0, title: titles[$0.noteID]) }]
        },
        Tool(name: "list_tags", description: "Every #tag in use with how many notes have it, most used first.", readOnly: true) { _ in
            let counts = Dictionary(NoteStore.loadAll().flatMap(\.tags).map { ($0, 1) }, uniquingKeysWith: +)
            return counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { ["tag": $0.key, "count": $0.value] }
        },
        Tool(name: "list_folders", description: "The folders, with their ids and how many notes each holds.", readOnly: true) { _ in
            let notes = NoteStore.loadAll()
            return NoteStore.folders().map { f in ["id": f.id, "name": f.name, "notes": notes.filter { $0.folderID == f.id }.count] }
        },
        Tool(name: "create_note",
             description: "Create a note from Markdown (first line = title). Plain by default; with url it belongs to that web page and shows there in the browser panel. Notes for apps can't be created from here.",
             properties: ["text": text("The note, in Markdown"), "url": text("Optional web page the note is about"),
                          "folder": text("Optional folder name or id")],
             required: ["text"]) { args in
            let body = try string(args, "text")
            var target = ""
            if let url = args["url"] as? String, !url.isEmpty {
                target = URL(string: url.contains("://") ? url : "https://" + url).map(Note.pageTarget) ?? ""
                guard !target.isEmpty else { throw ToolError(message: "url must be a web address, like https://github.com/apple/swift") }
            }
            let folder = try (args["folder"] as? String).flatMap { $0.isEmpty ? nil : try folderID($0) }
            var note = Note(kind: .url, target: target, label: String(target.prefix { $0 != "/" }), text: body)
            try NoteStore.save(note)
            if let folder {
                note.folderID = folder
                try NoteStore.saveMeta(note)
            }
            let saved = try fetch(note.id)
            return ["id": saved.id, "title": saved.title, "updated_at": stamp(saved)]
        },
        Tool(name: "append_to_note",
             description: "Add Markdown to the end of a note, on a new line. The safe way to add to a note.",
             properties: ["id": text("The note's id"), "text": text("Markdown to add")], required: ["id", "text"]) { args in
            var note = try fetchWritable(try string(args, "id"))
            let addition = try string(args, "text")
            note.text = note.text.isEmpty ? addition : note.text + (note.text.hasSuffix("\n") ? "" : "\n") + addition
            return try save(note)
        },
        Tool(name: "replace_note_text",
             description: "Replace a note's whole text. Pass updated_at from get_note as expected_updated_at: if the note changed since, nothing is replaced.",
             properties: ["id": text("The note's id"), "text": text("The new Markdown text"),
                          "expected_updated_at": number("updated_at from get_note")],
             required: ["id", "text"], destructive: true) { args in
            var note = try fetchWritable(try string(args, "id"))
            if let raw = args["expected_updated_at"] {
                // Models send numbers as 1.73e12, 1730000000000.0 or "1730000000000"; any of them is checked, never skipped.
                guard let expected = (raw as? NSNumber).map({ Int64($0.doubleValue.rounded()) }) ?? (raw as? String).flatMap({ Double($0) }).map({ Int64($0.rounded()) })
                else { throw ToolError(message: "expected_updated_at must be the number updated_at from get_note") }
                guard expected == stamp(note) else {
                    throw ToolError(message: "This note changed since you read it (updated_at is now \(stamp(note))). Call get_note and try again.")
                }
            }
            note.text = try string(args, "text")
            return try save(note)
        },
        Tool(name: "update_note",
             description: "Pin or unpin a note, set its colour label, or move it to a folder. Its text is unchanged.",
             properties: ["id": text("The note's id"), "pinned": ["type": "boolean", "description": "Pin (true) or unpin (false)"],
                          "color": ["type": "string", "enum": NoteColor.allCases.map(\.rawValue) + ["none"], "description": "Colour label, or none"],
                          "folder": text("Folder name or id; empty string for no folder")],
             required: ["id"]) { args in
            var note = try fetch(try string(args, "id"))  // a locked note can be pinned or moved, as in the app
            guard ["pinned", "color", "folder"].contains(where: { args[$0] != nil }) else {
                throw ToolError(message: "Give pinned, color or folder to change")
            }
            if let pinned = args["pinned"] as? Bool { note.pinned = pinned }
            if let color = args["color"] as? String {
                guard color == "none" || NoteColor(rawValue: color) != nil else {
                    throw ToolError(message: "color is one of \((NoteColor.allCases.map(\.rawValue) + ["none"]).joined(separator: ", "))")
                }
                note.color = NoteColor(rawValue: color)
            }
            if let folder = args["folder"] as? String { note.folderID = folder.isEmpty ? nil : try folderID(folder) }
            try NoteStore.saveMeta(note)
            let saved = try fetch(note.id)
            return summary(saved, folderNames()).merging(["updated_at": stamp(saved)]) { $1 }
        },
        Tool(name: "set_task_done",
             description: "Tick or untick a checklist item (\"- [ ] …\"). line is its 0-based line in the note's text, as list_tasks and get_note's dates give it.",
             properties: ["id": text("The note's id"), "line": number("0-based line number"),
                          "done": ["type": "boolean", "description": "true ticks it, false unticks it"]],
             required: ["id", "line", "done"]) { args in
            var note = try fetchWritable(try string(args, "id"))
            guard let line = args["line"] as? Int, let done = args["done"] as? Bool else {
                throw ToolError(message: "line (a number) and done (true or false) are required")
            }
            guard let ticked = settingTask(note.text, line: line, done: done) else {
                throw ToolError(message: "Line \(line) isn't a checklist item (\"- [ ] …\")")
            }
            if ticked == note.text { return ["id": note.id, "updated_at": stamp(note)] }
            note.text = ticked
            return try save(note)
        },
    ]

    // MARK: Helpers

    private static func text(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private static func number(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }

    private static func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String else { throw ToolError(message: "\(key) is required (a string)") }
        return value
    }

    private static func limit(_ args: [String: Any], _ fallback: Int, _ most: Int) -> Int {
        min(max((args["limit"] as? Int) ?? fallback, 1), most)
    }

    /// updated_at as whole milliseconds: what replace_note_text compares, so a model never has to copy a fraction.
    static func stamp(_ note: Note) -> Int64 { Int64(note.updatedAt.rounded()) }

    // shortcut: reads every note to find one; fine for thousands of notes, add a by-id query if that ever shows up.
    private static func fetch(_ id: String) throws -> Note {
        guard let note = NoteStore.loadAll().first(where: { $0.id == id }) else {
            throw ToolError(message: "No note with id \(id). Find ids with search_notes or list_notes.")
        }
        return note
    }

    private static func fetchWritable(_ id: String) throws -> Note {
        let note = try fetch(id)
        guard !note.locked else { throw ToolError(message: "This note is locked. Its text can only be changed in NoteAnywhere, after unlocking it.") }
        return note
    }

    /// Saves new text the way the app does (snapshot, sync flag, change signal), then checks it landed.
    private static func save(_ note: Note) throws -> [String: Any] {
        var note = note
        note.updatedAt = Date().timeIntervalSince1970 * 1000
        try NoteStore.save(note)
        let saved = try fetch(note.id)
        guard saved.text == note.text else { throw ToolError(message: "The note wasn't saved; it may have been locked or deleted meanwhile.") }
        return ["id": saved.id, "title": saved.title, "updated_at": stamp(saved)]
    }

    private static func folderNames() -> [String: String] {
        Dictionary(NoteStore.folders().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    private static func folderID(_ nameOrID: String) throws -> String {
        let folders = NoteStore.folders()
        guard let folder = folders.first(where: { $0.id == nameOrID })
                ?? folders.first(where: { $0.name.caseInsensitiveCompare(nameOrID) == .orderedSame }) else {
            throw ToolError(message: "No folder \"\(nameOrID)\". Folders: \(folders.map(\.name).joined(separator: ", "))")
        }
        return folder.id
    }

    private static func summary(_ note: Note, _ folders: [String: String]) -> [String: Any] {
        var s: [String: Any] = ["id": note.id, "title": note.title, "updated": iso(note.updatedAt)]
        if note.hasSource { s["source"] = note.shortSource }
        if note.pinned { s["pinned"] = true }
        if let color = note.color { s["color"] = color.rawValue }
        if let folder = note.folderID.flatMap({ folders[$0] }) { s["folder"] = folder }
        if note.locked { s["locked"] = true }
        return s
    }

    private static func task(_ item: DatedLine, title: String?) -> [String: Any] {
        var t: [String: Any] = ["day": item.day, "text": item.text, "line": item.line]
        if item.isTask { t["task"] = true; t["done"] = item.done }
        if let title { t["note_id"] = item.noteID; t["note_title"] = title }
        return t
    }

    /// The text with the checklist item on `line` ticked or not; nil if that line isn't a checklist item.
    static func settingTask(_ text: String, line: Int, done: Bool) -> String? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.indices.contains(line), let box = lines[line].firstMatch(of: #/^\s*[-*+]\s+\[([ xX])\]/#) else { return nil }
        lines[line].replaceSubrange(box.1.startIndex..<box.1.endIndex, with: done ? "x" : " ")
        return lines.joined(separator: "\n")
    }

    /// Up to ~160 characters around the first word of the query found in the text, on one line.
    static func snippet(_ text: String, _ query: String) -> String? {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }
        guard let hit = words.lazy.compactMap({ text.range(of: $0, options: .caseInsensitive) }).first else { return nil }
        let start = text.index(hit.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(hit.upperBound, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
        let flat = text[start..<end].split(whereSeparator: \.isNewline).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + flat + (end < text.endIndex ? "…" : "")
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f
    }()

    static func iso(_ ms: Double) -> String { isoFormatter.string(from: Date(timeIntervalSince1970: ms / 1000)) }

    static func parseDate(_ text: String) -> Date? {
        if let date = isoFormatter.date(from: text) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        day.timeZone = .current
        return day.date(from: text)
    }

    // MARK: JSON-RPC

    private static func call(_ tool: Tool, _ args: [String: Any]) -> [String: Any] {
        let outcome: (String, Bool)
        do {
            outcome = (json(try tool.run(args)), false)
        } catch let error as ToolError {
            outcome = (error.message, true)
        } catch {
            outcome = ("\(error)", true)
        }
        return ["content": [["type": "text", "text": outcome.0]], "isError": outcome.1]
    }

    private static func error(_ id: Any, _ code: Int, _ message: String, data: [String: Any]? = nil) -> Data? {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        return encode(["jsonrpc": "2.0", "id": id, "error": error])
    }

    // Sorted keys: the same tool list byte for byte every time, which clients can cache.
    private static func encode(_ object: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func json(_ object: Any) -> String { encode(object).map { String(decoding: $0, as: UTF8.self) } ?? "null" }
}
