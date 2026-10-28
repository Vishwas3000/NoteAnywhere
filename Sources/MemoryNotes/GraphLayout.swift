import Accelerate
import CoreGraphics

/// The knowledge graph: a node per note, a hub per app or site, and three kinds of edges.
/// Notes come first in `nodes`, hubs after them, so hiding the hubs is a prefix of the same indices.
struct Graph {
    struct Node: Identifiable {
        let id: String  // the note id, or "app:bundle.id" / "url:host" for a hub
        let title: String
        let note: Note  // a hub's first note, which gives it its icon
        var isHub: Bool { id != note.id }
    }

    struct Edge: Hashable {
        enum Kind: CaseIterable { case link, source, similar }
        let a: Int, b: Int
        let kind: Kind
    }

    /// MiniLM cosine from which two notes count as related (unrelated pairs sit below ~0.25).
    static let similarity: Float = 0.5
    /// Most similar-meaning edges per note, strongest first, so the graph doesn't turn into a hairball.
    static let similarPerNote = 3

    private(set) var nodes: [Node] = []
    private(set) var edges: [Edge] = []
    private(set) var noteCount = 0

    init(notes: [Note], vectors: [String: [Float]]) {
        nodes = notes.map { Node(id: $0.id, title: $0.title, note: $0) }
        noteCount = notes.count
        let index = Dictionary(notes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var paired = Set<[Int]>()

        for (i, note) in notes.enumerated() {
            for match in note.text.matches(of: #/note://([0-9A-Fa-f-]+)/#) {
                guard let j = index[String(match.1)], j != i, paired.insert([min(i, j), max(i, j)]).inserted else { continue }
                edges.append(Edge(a: min(i, j), b: max(i, j), kind: .link))
            }
        }

        var hubs: [String: Int] = [:]
        for (i, note) in notes.enumerated() {
            let key = String(note.target.prefix { $0 != "/" })  // bundle id or host, like IconStore
            guard !key.isEmpty else { continue }
            let id = "\(note.kind.rawValue):\(key)"
            if hubs[id] == nil {
                hubs[id] = nodes.count
                nodes.append(Node(id: id, title: note.kind == .app && !note.label.isEmpty ? note.label : key, note: note))
            }
            edges.append(Edge(a: i, b: hubs[id]!, kind: .source))
        }

        // Strongest pairs first; a pair is kept only while both notes have room, so no note gets more than k.
        let embedded = notes.indices.compactMap { i in vectors[notes[i].id].map { (i, $0) } }
        var candidates: [(score: Float, a: Int, b: Int)] = []
        for (x, (i, u)) in embedded.enumerated() {
            for (j, v) in embedded[(x + 1)...] where u.count == v.count && !paired.contains([i, j]) {
                let score = vDSP.dot(u, v)  // vectors are normalized, so this is the cosine
                if score >= Self.similarity { candidates.append((score, i, j)) }
            }
        }
        var count = [Int](repeating: 0, count: notes.count)
        for c in candidates.sorted(by: { $0.score > $1.score }) where count[c.a] < Self.similarPerNote && count[c.b] < Self.similarPerNote {
            edges.append(Edge(a: c.a, b: c.b, kind: .similar))
            count[c.a] += 1
            count[c.b] += 1
        }
    }
}

/// Force-directed layout after d3-force: repulsion between all nodes, springs along edges, a gentle pull to the
/// center and velocity damping. Forces scale with `alpha`, which cools toward zero, so the simulation always comes to rest.
struct GraphLayout {
    static let repulsion = 150.0
    static let centerPull = 0.03
    static let damping = 0.4  // share of velocity lost per step
    static let alphaMin = 0.001
    static let alphaDecay = 1 - pow(alphaMin, 1.0 / 300)  // ~300 steps (5 s at 60 fps) from hot to rest

    /// Rest length and stiffness per edge kind: explicit links pull hardest, similar meaning least.
    static func spring(_ kind: Graph.Edge.Kind) -> (length: Double, strength: Double) {
        switch kind {
        case .link: (60, 1)
        case .source: (50, 1)
        case .similar: (70, 0.15)
        }
    }

    private struct Spring { let a: Int, b: Int, length: Double, strength: Double, bias: Double }

    private(set) var positions: [CGPoint]
    private var velocities: [CGVector]
    private let springs: [Spring]
    private var pinned: [Int: CGPoint] = [:]
    var alpha = 1.0
    private var alphaTarget = 0.0

    var isSettled: Bool { alpha < Self.alphaMin }

    /// Nodes missing from `start` begin on a sunflower spiral, which spreads them evenly without randomness.
    init(count: Int, edges: [Graph.Edge], start: [Int: CGPoint] = [:]) {
        positions = (0..<count).map { i in
            start[i] ?? {
                let r = 10 * (0.5 + Double(i)).squareRoot(), angle = Double(i) * .pi * (3 - 5.0.squareRoot())
                return CGPoint(x: r * cos(angle), y: r * sin(angle))
            }()
        }
        velocities = Array(repeating: .zero, count: count)
        var degree = [Int](repeating: 0, count: count)
        for e in edges { degree[e.a] += 1; degree[e.b] += 1 }
        // Like d3: a spring is softer on busy nodes, and the busier end (a hub) moves less.
        springs = edges.map { e in
            let (length, strength) = Self.spring(e.kind)
            return Spring(a: e.a, b: e.b, length: length, strength: strength / Double(min(degree[e.a], degree[e.b])),
                          bias: Double(degree[e.a]) / Double(degree[e.a] + degree[e.b]))
        }
    }

    mutating func step() {
        alpha += (alphaTarget - alpha) * Self.alphaDecay
        for s in springs {
            var dx = positions[s.b].x + velocities[s.b].dx - positions[s.a].x - velocities[s.a].dx
            var dy = positions[s.b].y + velocities[s.b].dy - positions[s.a].y - velocities[s.a].dy
            if dx == 0, dy == 0 { (dx, dy) = Self.jiggle(s.a, s.b) }
            let l = (dx * dx + dy * dy).squareRoot()
            let f = (l - s.length) / l * alpha * s.strength
            velocities[s.b].dx -= dx * f * s.bias
            velocities[s.b].dy -= dy * f * s.bias
            velocities[s.a].dx += dx * f * (1 - s.bias)
            velocities[s.a].dy += dy * f * (1 - s.bias)
        }
        // shortcut: O(n²) repulsion is fine for a few hundred notes; use a Barnes-Hut quadtree beyond ~1,000.
        for i in positions.indices {
            for j in (i + 1)..<positions.count {
                var dx = positions[j].x - positions[i].x, dy = positions[j].y - positions[i].y
                if dx == 0, dy == 0 { (dx, dy) = Self.jiggle(i, j) }
                let f = Self.repulsion * alpha / max(dx * dx + dy * dy, 1)
                velocities[i].dx -= dx * f
                velocities[i].dy -= dy * f
                velocities[j].dx += dx * f
                velocities[j].dy += dy * f
            }
        }
        for i in positions.indices {
            if let p = pinned[i] {
                positions[i] = p
                velocities[i] = .zero
                continue
            }
            velocities[i].dx = (velocities[i].dx - positions[i].x * Self.centerPull * alpha) * (1 - Self.damping)
            velocities[i].dy = (velocities[i].dy - positions[i].y * Self.centerPull * alpha) * (1 - Self.damping)
            positions[i].x += velocities[i].dx
            positions[i].y += velocities[i].dy
        }
    }

    mutating func settle() {
        for _ in 0..<1000 where !isSettled { step() }
    }

    /// Holds a node under the pointer and keeps the rest warm so they follow, like dragging in Obsidian.
    mutating func pin(_ i: Int, at p: CGPoint) {
        pinned[i] = p
        positions[i] = p
        alphaTarget = 0.3
        alpha = max(alpha, 0.3)
    }

    mutating func unpin(_ i: Int) {
        pinned[i] = nil
        alphaTarget = 0
    }

    /// Nodes on the same spot have no direction to push apart in; nudge them a tiny, repeatable way.
    private static func jiggle(_ i: Int, _ j: Int) -> (CGFloat, CGFloat) {
        let angle = Double(i * 7 + j)
        return (cos(angle) * 1e-3, sin(angle) * 1e-3)
    }
}

/// Where the graph is on screen: `offset` is the graph origin's distance from the view's center.
struct Camera {
    var scale: CGFloat = 1
    var offset = CGSize.zero

    func screen(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + offset.width + p.x * scale, y: size.height / 2 + offset.height + p.y * scale)
    }

    func world(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (p.x - size.width / 2 - offset.width) / scale, y: (p.y - size.height / 2 - offset.height) / scale)
    }

    /// Keeps the graph point under `p` where it is.
    func zoomed(by factor: CGFloat, around p: CGPoint, in size: CGSize) -> Camera {
        let s = min(max(scale * factor, 0.1), 5), k = s / scale
        let x = p.x - size.width / 2, y = p.y - size.height / 2
        return Camera(scale: s, offset: CGSize(width: x - (x - offset.width) * k, height: y - (y - offset.height) * k))
    }

    static func fitting(_ points: [CGPoint], in size: CGSize) -> Camera {
        guard !points.isEmpty, size.width > 0, size.height > 0 else { return Camera() }
        let xs = points.map(\.x), ys = points.map(\.y)
        let (minX, maxX, minY, maxY) = (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
        let margin: CGFloat = 60  // room for node radii and labels
        let s = min((size.width - 2 * margin) / max(maxX - minX, 1), (size.height - 2 * margin) / max(maxY - minY, 1))
        let scale = min(max(s, 0.1), 1.5)
        return Camera(scale: scale, offset: CGSize(width: -(minX + maxX) / 2 * scale, height: -(minY + maxY) / 2 * scale))
    }

    /// A step of the way there, so following the settling graph is smooth.
    func approaching(_ target: Camera) -> Camera {
        let k: CGFloat = 0.15
        return Camera(scale: scale + (target.scale - scale) * k,
                      offset: CGSize(width: offset.width + (target.offset.width - offset.width) * k,
                                     height: offset.height + (target.offset.height - offset.height) * k))
    }
}
