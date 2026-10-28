import SwiftUI

/// The Mac's knowledge graph on a touch screen: each note is a dot joined to its app or site, to the notes it links
/// to and to notes with a similar meaning. Drag to pan, pinch to zoom, tap a note to open it (a hub to highlight its
/// notes), touch and hold a note to highlight its neighbors and drag it around.
struct GraphView: View {
    @ObservedObject private var model = NotesModel.shared
    @AppStorage("graphShowsLinks") private var showLinks = true
    @AppStorage("graphShowsSources") private var showSources = true
    @AppStorage("graphShowsSimilar") private var showSimilar = true
    @AppStorage("graphShowsTags") private var showTags = true
    @State private var graph: Graph?
    // What the toggles show, kept in step: positions, node ids by index (to keep positions across rebuilds),
    // the shown edges and each node's number of them.
    @State private var layout = GraphLayout(count: 0, edges: [])
    @State private var placed: [String] = []
    @State private var shown: [Graph.Edge] = []
    @State private var degree: [Int] = []
    @State private var camera = Camera()
    @State private var autoFit = true  // follow the settling graph until the user pans, zooms or drags
    @State private var pinchStart: Camera?
    @State private var panStart: CGSize?
    @State private var held: Int?  // the node under a touch-and-hold
    @State private var focusedHub: String?
    @State private var opened: String?
    @State private var size = CGSize.zero
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            Group {
                if model.notes.isEmpty {
                    ContentUnavailableView("No Notes Yet", systemImage: "point.3.connected.trianglepath.dotted", description: Text(
                        "Each note shows up here as a dot, joined to its app or website, to the notes it links to and to notes with a similar meaning."))
                } else {
                    canvas
                        .overlay(alignment: .bottom) { if graph != nil, shown.isEmpty { noConnections } }
                        .onGeometryChange(for: CGSize.self, of: \.size) {
                            size = $0
                            if autoFit { fit() }
                        }
                        .task(id: model.notes) { await rebuild() }
                        .onChange(of: [showSources, showTags]) { Task { await rebuild() } }  // hubs that are off aren't built
                        .onChange(of: [showLinks, showSimilar]) { relayout() }
                }
            }
            .navigationTitle("Graph")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        autoFit = true
                        fit()
                    } label: {
                        Label("Fit Graph", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    Menu {
                        Toggle(isOn: $showLinks) { Label("Links", systemImage: "link") }
                        Toggle(isOn: $showSources) { Label("Sources", systemImage: "globe") }
                        Toggle(isOn: $showTags) { Label("Tags", systemImage: "number") }
                        Toggle(isOn: $showSimilar) { Label("Similar Meaning", systemImage: "sparkles") }
                    } label: {
                        Label("Connections", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .navigationDestination(item: $opened) { NoteDetailView(noteID: $0) }
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        TimelineView(.animation(paused: layout.isSettled)) { timeline in
            Canvas { ctx, size in draw(&ctx, size) } symbols: {
                ForEach(graph?.nodes.filter { $0.isHub && !$0.isTag } ?? []) { NoteIcon(note: $0.note, size: 40).tag($0.id) }
            }
            .onChange(of: timeline.date) { tick() }
        }
        .drawingGroup()
        .contentShape(Rectangle())
        .gesture(panGesture)
        .simultaneousGesture(pinchGesture)
        .gesture(HoldGesture { state, p in hold(state, at: p) })
        .onTapGesture { p in
            if let i = hit(p) { activate(i) } else { focusedHub = nil }
        }
        .sensoryFeedback(.selection, trigger: held) { _, new in new != nil }
        .accessibilityLabel("Graph of notes")
        .accessibilityChildren {
            if let graph {
                AccessibleNodes(nodes: Array(graph.nodes.prefix(placed.count)), degree: degree, activate: activate).equatable()
            }
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        guard let graph else { return }
        let nodes = graph.nodes
        let points = layout.positions.map { camera.screen($0, in: size) }
        let center = held ?? focusedHub.flatMap { placed.firstIndex(of: $0) }
        let lit: Set<Int>? = center.map { c in
            shown.reduce(into: [c]) { set, e in if e.a == c { set.insert(e.b) } else if e.b == c { set.insert(e.a) } }
        }
        let dim = points.indices.map { !(lit?.contains($0) ?? true) }
        let boost = contrast == .increased ? 1.8 : 1

        // One stroke per edge kind and state (normal, dimmed, highlighted), however many edges there are.
        for kind in Graph.Edge.Kind.allCases {
            var paths = [Path(), Path(), Path()]
            for e in shown where e.kind == kind {
                let state = if let center { e.a == center || e.b == center ? 2 : 1 } else { 0 }
                paths[state].move(to: points[e.a])
                paths[state].addLine(to: points[e.b])
            }
            let style = Self.stroke(kind)
            ctx.stroke(paths[0], with: .color(.primary.opacity(Self.edgeOpacity(kind) * boost)), style: style)
            ctx.stroke(paths[1], with: .color(.primary.opacity(0.05 * boost)), style: style)
            ctx.stroke(paths[2], with: .color(accent), style: StrokeStyle(lineWidth: style.lineWidth + 0.6, dash: style.dash))
        }

        var bright = Path(), faint = Path()
        for i in points.indices where !nodes[i].isHub {
            let circle = Path(ellipseIn: disc(points[i], screenRadius(i)))
            if dim[i] { faint.addPath(circle) } else { bright.addPath(circle) }
        }
        ctx.fill(faint, with: .color(accent.opacity(0.2)))
        var glow = ctx  // only the held node and its neighbors glow, so the blur stays cheap
        if lit != nil { glow.addFilter(.shadow(color: accent.opacity(0.8), radius: 6)) }
        glow.fill(bright, with: .color(accent))
        if contrast == .increased { ctx.stroke(bright, with: .color(.primary.opacity(0.7)), lineWidth: 1) }
        if let center, !nodes[center].isHub {
            ctx.stroke(Path(ellipseIn: disc(points[center], screenRadius(center) + 3)), with: .color(accent), lineWidth: 2)
        }

        for i in points.indices where nodes[i].isHub {
            let rect = disc(points[i], screenRadius(i))
            var hub = ctx
            if dim[i] { hub.opacity = 0.25 }
            hub.fill(Path(ellipseIn: rect), with: .color(surface))
            hub.stroke(Path(ellipseIn: rect), with: .color(i == center ? accent : .primary.opacity(0.25 * boost)), lineWidth: i == center ? 2 : 1)
            if nodes[i].isTag {
                hub.draw(Text("#").font(.system(size: rect.height * 0.5, weight: .bold, design: .rounded)).foregroundStyle(accent),
                         at: CGPoint(x: rect.midX, y: rect.midY))
            } else if let icon = hub.resolveSymbol(id: nodes[i].id) {
                hub.draw(icon, in: rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2))
            }
        }

        // Labels fade in as you zoom, like Obsidian; hubs and the held node's neighbors always have one.
        let fade = min(max((camera.scale - 0.85) / 0.25, 0), 1)
        let onScreen = CGRect(origin: .zero, size: size).insetBy(dx: -80, dy: -40)
        for i in points.indices where i != center && !dim[i] && onScreen.contains(points[i]) {
            let opacity = nodes[i].isHub || lit != nil ? 1 : fade
            guard opacity > 0.25 else { continue }  // fainter reads as a smudge, not a label
            var label = ctx
            label.opacity = opacity
            if nodes[i].isHub || lit != nil { label.addFilter(.shadow(color: surface, radius: 2)) }  // a halo over busy edges
            label.draw(Text(Self.short(nodes[i].title)).font(nodes[i].isHub ? .caption.weight(.semibold) : .caption)
                        .foregroundStyle(lit != nil ? .primary : .secondary),
                       at: CGPoint(x: points[i].x, y: points[i].y + screenRadius(i) + 2), anchor: .top)
        }

        if let center {
            let node = nodes[center]
            let detail = node.isHub ? "\(degree[center]) notes" : node.note.place
            let tip = ctx.resolve(Text(node.title).font(.callout.weight(.semibold))
                                  + Text("\n" + detail).font(.caption).foregroundStyle(.secondary))
            let box = tip.measure(in: CGSize(width: 260, height: 120))
            // Above the finger rather than under it.
            let rect = CGRect(x: min(max(points[center].x - box.width / 2 - 8, 8), size.width - box.width - 24),
                              y: points[center].y - screenRadius(center) - box.height - 22, width: box.width + 16, height: box.height + 8)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(surface.opacity(0.95)))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(.primary.opacity(0.15 * boost)), lineWidth: 0.5)
            ctx.draw(tip, in: rect.insetBy(dx: 8, dy: 4))
        }
    }

    private var accent: Color {
        colorScheme == .dark ? Color(red: 1, green: 0.839, blue: 0.039) : Color(red: 0.78, green: 0.541, blue: 0)
    }

    /// Hub and tooltip background: opaque, so edges don't show through.
    private var surface: Color { colorScheme == .dark ? Color(white: 0.17) : .white }

    private static func stroke(_ kind: Graph.Edge.Kind) -> StrokeStyle {
        switch kind {
        case .link: StrokeStyle(lineWidth: 1.4)
        case .source: StrokeStyle(lineWidth: 0.8)
        case .tag: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.5, 3.5])
        case .similar: StrokeStyle(lineWidth: 1, dash: [3, 3])
        }
    }

    private static func edgeOpacity(_ kind: Graph.Edge.Kind) -> Double {
        switch kind {
        case .link: 0.45
        case .source: 0.18
        case .tag: 0.4
        case .similar: 0.22
        }
    }

    private static func short(_ title: String) -> String { title.count > 28 ? title.prefix(27) + "…" : title }

    /// Sized by connections, like Obsidian; hubs are bigger so their icon fits.
    private func screenRadius(_ i: Int) -> CGFloat {
        let d = CGFloat(degree[i]).squareRoot()
        let r = graph?.nodes[i].isHub == true ? min(12 + 1.5 * d, 22) : min(4 + 1.8 * d, 14)
        return max(r * camera.scale, 2)
    }

    private func disc(_ p: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r) }

    // MARK: Interaction

    /// Fingers are blunter than pointers: a node counts as hit within 22 pt (a 44 pt target).
    private func hit(_ p: CGPoint) -> Int? {
        var best: (i: Int, d: CGFloat)?
        for (i, q) in layout.positions.enumerated() {
            let s = camera.screen(q, in: size), d = hypot(s.x - p.x, s.y - p.y)
            if d <= max(screenRadius(i) + 4, 22), d < best?.d ?? .infinity { best = (i, d) }
        }
        return best?.i
    }

    private func activate(_ i: Int) {
        guard let node = graph?.nodes[i] else { return }
        if node.isHub { focusedHub = focusedHub == node.id ? nil : node.id } else { opened = node.id }
    }

    /// Touch and hold a node to light it up with its neighbors; keep holding and drag to move it (the rest follow).
    private func hold(_ state: UIGestureRecognizer.State, at p: CGPoint) {
        switch state {
        case .began:
            held = hit(p)
            if held != nil { autoFit = false }
        case .changed:
            if let i = held { layout.pin(i, at: camera.world(p, in: size)) }
        default:
            if let i = held { layout.unpin(i) }
            held = nil
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                guard held == nil else { return }  // the finger is moving a held node
                autoFit = false
                let start = panStart ?? camera.offset
                panStart = start
                camera.offset = CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height)
            }
            .onEnded { _ in panStart = nil }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                autoFit = false
                let start = pinchStart ?? camera
                pinchStart = start
                camera = start.zoomed(by: v.magnification, around: v.startLocation, in: size)
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func tick() {
        layout.step()
        if autoFit { camera = camera.approaching(.fitting(layout.positions, in: size)) }
    }

    private func fit() { camera = .fitting(layout.positions, in: size) }

    // MARK: Building

    private func rebuild() async {
        let notes = model.notes, sources = showSources, tags = showTags
        let built = await Task.detached(priority: .userInitiated) {
            Graph(notes: notes, vectors: NoteStore.vectors().mapValues(\.vector), sources: sources, tags: tags)
        }.value
        guard !Task.isCancelled else { return }
        graph = built
        relayout()
    }

    /// Lays out what the toggles show; nodes already on screen stay where they are.
    private func relayout() {
        guard let graph else { return }
        let edges = graph.edges.filter {
            switch $0.kind {
            case .link: showLinks
            case .source: showSources
            case .tag: showTags
            case .similar: showSimilar
            }
        }
        let ids = graph.nodes.map(\.id)
        let old = Dictionary(zip(placed, layout.positions), uniquingKeysWith: { a, _ in a })
        var start: [Int: CGPoint] = [:]
        for (i, id) in ids.enumerated() { start[i] = old[id] }
        let kept = start.count
        for e in edges {  // a new node starts on a placed neighbor, e.g. a hub on one of its notes
            if start[e.a] == nil, let p = start[e.b] { start[e.a] = p } else if start[e.b] == nil, let p = start[e.a] { start[e.b] = p }
        }
        var next = GraphLayout(count: ids.count, edges: edges, start: start)
        if kept > ids.count / 2 { next.alpha = 0.3 }  // mostly placed: settle gently instead of starting over
        if reduceMotion { next.settle() }
        layout = next
        placed = ids
        shown = edges
        degree = edges.reduce(into: [Int](repeating: 0, count: ids.count)) { $0[$1.a] += 1; $0[$1.b] += 1 }
        held = nil  // its index may point elsewhere now
        if reduceMotion, autoFit { fit() }
    }

    private var noConnections: some View {
        VStack(spacing: 4) {
            Text("No Connections").font(.headline)
            Text(showLinks && showSources && showTags && showSimilar
                 ? "Type #tags in your notes, link notes with [text](note://id), or keep writing: similar notes join up once indexed."
                 : "Turn on Links, Sources, Tags or Similar Meaning to see how your notes connect.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(14)
        .glassBackground()
        .padding(16)
    }
}

/// UIKit's long press, for the location SwiftUI's doesn't report; it keeps reporting while the finger moves.
private struct HoldGesture: UIGestureRecognizerRepresentable {
    let action: (UIGestureRecognizer.State, CGPoint) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer()
        press.minimumPressDuration = 0.35
        return press
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        action(recognizer.state, context.converter.localLocation)
    }
}

/// What VoiceOver reads instead of the canvas: every node with its connections, and an action to open it.
/// Equatable so the list isn't rebuilt on every animation frame.
private struct AccessibleNodes: View, Equatable {
    let nodes: [Graph.Node]
    let degree: [Int]
    let activate: (Int) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.degree == b.degree && a.nodes.map(\.note) == b.nodes.map(\.note) && a.nodes.map(\.id) == b.nodes.map(\.id)
    }

    var body: some View {
        ForEach(nodes.indices, id: \.self) { i in
            let node = nodes[i]
            Text(node.title)
                .accessibilityValue(node.isHub ? Text("^[\(degree[i]) note](inflect: true)")
                                               : Text("^[\(degree[i]) connection](inflect: true), \(node.note.place)"))
                .accessibilityHint(node.isHub ? "Highlights its notes" : "Opens the note")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { activate(i) }
        }
    }
}

extension View {
    /// Liquid Glass on iOS 26, a material before it.
    @ViewBuilder
    func glassBackground() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
