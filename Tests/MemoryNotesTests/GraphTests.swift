import CoreGraphics
import Testing
@testable import MemoryNotes

private func note(_ id: String, _ target: String = "", kind: Note.Kind = .url, label: String = "", text: String = "") -> Note {
    Note(id: id, kind: kind, target: target, label: label, text: text)
}

private func distance(_ p: CGPoint, _ q: CGPoint) -> Double { hypot(p.x - q.x, p.y - q.y) }

@Test func linkEdgesAreUndirectedAndSkipMissingNotes() {
    let a = note("a1", text: "See [b](note://b2), again note://b2, a gone note://ff and myself note://a1")
    let b = note("b2", text: "Back to [a](note://a1)")
    let c = note("c3", text: "[c](note://c3)")
    let graph = Graph(notes: [a, b, c], vectors: [:])
    #expect(graph.edges == [Graph.Edge(a: 0, b: 1, kind: .link)])
}

@Test func notesShareOneHubPerAppOrHost() {
    let notes = [
        note("a1", "com.tinyspeck.slackmacgap/Acme/Alex Rivera (DM)", kind: .app, label: "Slack"),
        note("b2", "com.tinyspeck.slackmacgap", kind: .app, label: "Slack"),
        note("c3", "github.com/vercel/next.js"),
        note("d4", "github.com"),
        note("e5"),  // a new website note without an address yet
    ]
    let graph = Graph(notes: notes, vectors: [:])
    #expect(graph.noteCount == 5)
    #expect(graph.nodes.dropFirst(5).map(\.title) == ["Slack", "github.com"])
    #expect(graph.nodes.map(\.isHub) == Array(repeating: false, count: 5) + [true, true])
    #expect(graph.edges == [
        Graph.Edge(a: 0, b: 5, kind: .source), Graph.Edge(a: 1, b: 5, kind: .source),
        Graph.Edge(a: 2, b: 6, kind: .source), Graph.Edge(a: 3, b: 6, kind: .source),
    ])
}

/// The center note is similar (0.9, 0.8, 0.7, 0.6) to four others: all pass the threshold,
/// but it keeps only its three strongest. Unrelated and unembedded notes get nothing.
@Test func similarityKeepsTopKAboveThreshold() {
    let center: [Float] = [1, 0, 0, 0, 0, 0]
    func near(_ cos: Float, axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 6)
        v[0] = cos
        v[axis] = (1 - cos * cos).squareRoot()
        return v
    }
    let ids = ["c0", "a1", "a2", "a3", "a4", "f5", "e6"]
    let vectors = [
        "c0": center, "a1": near(0.9, axis: 1), "a2": near(0.8, axis: 2), "a3": near(0.7, axis: 3),
        "a4": near(0.6, axis: 4), "f5": [0, 0, 0, 0, 0, 1],  // e6 has no vector yet
    ]
    let graph = Graph(notes: ids.map { note($0) }, vectors: vectors)
    let similar = graph.edges.filter { $0.kind == .similar }
    let neighbors = { (i: Int) in Set(similar.compactMap { $0.a == i ? $0.b : $0.b == i ? $0.a : nil }) }
    #expect(neighbors(0) == [1, 2, 3])
    #expect(neighbors(5).isEmpty && neighbors(6).isEmpty)
    #expect((0..<7).allSatisfy { neighbors($0).count <= Graph.similarPerNote })
    #expect(similar.allSatisfy { Double(zip(vectors[ids[$0.a]]!, vectors[ids[$0.b]]!).map(*).reduce(0, +)) >= 0.5 - 1e-6 })
}

@Test func linkedNotesAreNotAlsoSimilar() {
    let notes = [note("a1", text: "note://b2"), note("b2")]
    let graph = Graph(notes: notes, vectors: ["a1": [1, 0], "b2": [1, 0]])
    #expect(graph.edges == [Graph.Edge(a: 0, b: 1, kind: .link)])
}

@Test func connectedNodesEndCloserThanUnconnected() {
    let edges = [Graph.Edge(a: 0, b: 1, kind: .link), Graph.Edge(a: 2, b: 3, kind: .similar)]
    var layout = GraphLayout(count: 6, edges: edges)
    for _ in 0..<300 { layout.step() }
    let p = layout.positions
    #expect(distance(p[0], p[1]) < distance(p[0], p[2]))
    #expect(distance(p[0], p[1]) < distance(p[0], p[4]))
    #expect(distance(p[2], p[3]) < distance(p[2], p[5]))
}

@Test func simulationSettles() {
    let edges = (1..<40).map { Graph.Edge(a: 0, b: $0, kind: .source) } + [Graph.Edge(a: 1, b: 2, kind: .link)]
    var layout = GraphLayout(count: 40, edges: edges)
    layout.settle()
    #expect(layout.isSettled)
    let before = layout.positions
    layout.step()
    #expect(zip(before, layout.positions).allSatisfy { distance($0, $1) < 0.1 })
}

@Test func overlappingNodesSeparateWithoutNaN() {
    let edges = [Graph.Edge(a: 0, b: 1, kind: .link), Graph.Edge(a: 2, b: 3, kind: .source)]
    var layout = GraphLayout(count: 4, edges: edges, start: Dictionary(uniqueKeysWithValues: (0..<4).map { ($0, CGPoint(x: 5, y: 5)) }))
    for _ in 0..<50 { layout.step() }
    #expect(layout.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    #expect(distance(layout.positions[0], layout.positions[1]) > 1)
}

@Test func pinnedNodeStaysUnderThePointer() {
    var layout = GraphLayout(count: 3, edges: [Graph.Edge(a: 0, b: 1, kind: .link)])
    layout.pin(0, at: CGPoint(x: 400, y: -300))
    for _ in 0..<100 { layout.step() }
    #expect(layout.positions[0] == CGPoint(x: 400, y: -300))
    #expect(!layout.isSettled)  // kept warm while dragging
    layout.unpin(0)
    layout.settle()
    #expect(layout.isSettled)
}

@Test func notesSharingATagMeetAtItsHub() {
    let notes = [note("a1", text: "#ml basics"), note("b2", text: "more #ML and #project/notes"), note("c3", text: "none")]
    let graph = Graph(notes: notes, vectors: [:], sources: false)
    #expect(graph.nodes.dropFirst(3).map(\.title) == ["#ml", "#project/notes", "#project"])
    #expect(graph.nodes.dropFirst(3).allSatisfy { $0.isTag })
    #expect(Set(graph.edges) == [
        Graph.Edge(a: 0, b: 3, kind: .tag), Graph.Edge(a: 1, b: 3, kind: .tag),
        Graph.Edge(a: 1, b: 4, kind: .tag), Graph.Edge(a: 4, b: 5, kind: .tag),  // nested tag under its parent
    ])
    #expect(Graph(notes: notes, vectors: [:], sources: false, tags: false).nodes.count == 3)
}
