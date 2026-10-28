import Embeddings
import Foundation

/// Hybrid search: MiniLM similarity plus a boost for notes containing the query's words.
/// The app keeps vectors in the embeddings table; the browser host only reads them, so it embeds just the query.
actor SearchIndex {
    struct Hit: Codable, Hashable {
        let note: Note
        let score: Double
    }

    static let shared = SearchIndex()
    private static let modelID = NoteStore.embeddingModel
    private static let modelsDir = NoteStore.root.appendingPathComponent("models")
    private static let localModel = modelsDir.appendingPathComponent("models/" + modelID)

    /// Whether the model is on disk, so searching won't start the one-time download.
    static var hasModel: Bool { FileManager.default.fileExists(atPath: localModel.appendingPathComponent("config.json").path) }

    private var bundle: Bert.ModelBundle?
    private var loading: Task<Bert.ModelBundle?, Never>?
    private var cache = NoteStore.vectors()

    /// Loads the model, downloading it once (~90 MB) on first use. Returns nil offline before the first download.
    private func model() async -> Bert.ModelBundle? {
        if let bundle { return bundle }
        if loading == nil {
            loading = Task {
                if Self.hasModel, let bundle = try? await Bert.loadModelBundle(from: Self.localModel) {
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

    /// Embeds new or changed notes. Called by the app; the host never writes vectors.
    func update(_ notes: [Note]) async {
        for note in notes where !note.locked && cache[note.id]?.updatedAt != note.updatedAt {
            guard let vector = await embed(Self.document(note)) else { break }
            cache[note.id] = (updatedAt: note.updatedAt, vector: vector)
            try? NoteStore.saveVector(note.id, updatedAt: note.updatedAt, vector: vector)
        }
    }

    /// A note that was just locked: its vector (made from readable text) is gone from the database too.
    func forget(_ id: String) { cache[id] = nil }

    func search(_ query: String, in notes: [Note], limit: Int = 20) async -> [Hit] {
        let notes = notes.filter { !$0.locked }
        // "#ml" lists exactly the notes with that tag (or one nested under it), newest first, like Obsidian.
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.wholeMatch(of: #/#[^\s#]+/#) != nil {
            let tag = trimmed.dropFirst().lowercased()
            return notes.filter { $0.hasTag(tag) }.sorted { $0.updatedAt > $1.updatedAt }.map { Hit(note: $0, score: 1) }
        }
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
