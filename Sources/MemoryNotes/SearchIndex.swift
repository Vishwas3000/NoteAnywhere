import Embeddings
import Foundation

/// Hybrid search: MiniLM similarity plus a boost for notes containing the query's words.
/// The app keeps vectors cached in embeddings.json; the browser host reads that cache so it only embeds the query.
actor SearchIndex {
    struct Hit: Codable, Hashable {
        let note: Note
        let score: Double
    }

    private struct Entry: Codable {
        let updatedAt: Double
        let vector: [Float]
    }

    static let shared = SearchIndex()
    private static let modelID = "sentence-transformers/all-MiniLM-L6-v2"
    private static let modelsDir = NoteStore.root.appendingPathComponent("models")
    // shortcut: one JSON file of all vectors (~3 MB per 1000 notes); move to SQLite if it grows past a few MB.
    private static let cacheURL = NoteStore.root.appendingPathComponent("embeddings.json")

    private var bundle: Bert.ModelBundle?
    private var loading: Task<Bert.ModelBundle?, Never>?
    private var cache: [String: Entry] = (try? JSONDecoder().decode(
        [String: Entry].self, from: Data(contentsOf: SearchIndex.cacheURL))) ?? [:]

    /// Loads the model, downloading it once (~90 MB) on first use. Returns nil offline before the first download.
    private func model() async -> Bert.ModelBundle? {
        if let bundle { return bundle }
        if loading == nil {
            loading = Task {
                let local = Self.modelsDir.appendingPathComponent("models/" + Self.modelID)
                if FileManager.default.fileExists(atPath: local.appendingPathComponent("config.json").path),
                   let bundle = try? await Bert.loadModelBundle(from: local) {
                    return bundle
                }
                do {
                    return try await Bert.loadModelBundle(from: Self.modelID, downloadBase: Self.modelsDir)
                } catch {
                    NSLog("MemoryNotes: search model unavailable, keyword search only: \(error)")
                    return nil
                }
            }
        }
        bundle = await loading?.value
        if bundle == nil { loading = nil }  // retry on the next search, e.g. once back online
        return bundle
    }

    private func embed(_ text: String) async -> [Float]? {
        guard let bundle = await model() else { return nil }
        var options = bundle.defaultEncodeOptions
        options.maxLength = 256  // MiniLM was trained on 256 tokens; longer notes are truncated
        options.postProcess = .meanPool(normalize: true)
        guard let tensor = try? bundle.encode(text, options: options) else { return nil }
        return await tensor.cast(to: Float.self).shapedArray(of: Float.self).scalars
    }

    private static func document(_ note: Note) -> String {
        "\(note.label) \(note.target)\n\(note.text)"
    }

    /// Embeds new or changed notes and forgets deleted ones. Called by the app; the host never writes the cache.
    func update(_ notes: [Note]) async {
        var changed = false
        let ids = Set(notes.map(\.id))
        for id in cache.keys where !ids.contains(id) {
            cache[id] = nil
            changed = true
        }
        for note in notes where cache[note.id]?.updatedAt != note.updatedAt {
            guard let vector = await embed(Self.document(note)) else { break }
            cache[note.id] = Entry(updatedAt: note.updatedAt, vector: vector)
            changed = true
        }
        if changed, let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }

    func search(_ query: String, in notes: [Note], limit: Int = 20) async -> [Hit] {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return [] }
        let queryVector = await embed(query)
        var hits: [Hit] = []
        for note in notes {
            let haystack = Self.document(note).lowercased()
            let keyword = Double(words.filter { haystack.contains($0) }.count) / Double(words.count)
            var similarity = 0.0
            if let queryVector {
                var vector = cache[note.id].flatMap { $0.updatedAt == note.updatedAt ? $0.vector : nil }
                if vector == nil { vector = await embed(Self.document(note)) }  // not indexed yet: embed on the fly
                if let vector { similarity = Double(zip(queryVector, vector).reduce(0) { $0 + $1.0 * $1.1 }) }
            }
            // Vectors are normalized, so the dot product is cosine similarity; unrelated MiniLM pairs sit below ~0.25.
            if similarity > 0.25 || keyword > 0 {
                hits.append(Hit(note: note, score: similarity + 0.5 * keyword))
            }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }
}
