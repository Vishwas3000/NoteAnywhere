import AppKit
import SwiftUI

/// Knowledge graph of all notes, like Obsidian's: each note is a dot joined to the app or site it belongs to,
/// to the notes it links to and to notes with a similar meaning. Click a note to open it, a hub to highlight its notes.
struct GraphView: View {
    @ObservedObject private var model = NotesModel.shared
    @AppStorage("graphShowsLinks") private var showLinks = true
    @AppStorage("graphShowsSources") private var showSources = true
    @AppStorage("graphShowsSimilar") private var showSimilar = true
    @State private var filter = ""
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
    @State private var drag: Drag?
    @State private var hovered: Int?
    @State private var focusedHub: String?
    @State private var size = CGSize.zero
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Drag { case node(Int), pan(from: CGSize) }

    var body: some View {
        if model.notes.isEmpty {
            ContentUnavailableView("No Notes Yet", systemImage: "point.3.connected.trianglepath.dotted", description: Text(
                "Each note shows up here as a dot, joined to its app or website, to the notes it links to and to notes with a similar meaning."))
        } else {
            canvas
                .overlay(alignment: .topTrailing) { controls }
                .overlay(alignment: .bottom) {
                    if graph != nil, shown.isEmpty { noConnections }
                }
                .onGeometryChange(for: CGSize.self, of: \.size) {
                    size = $0
                    if autoFit { fit() }
                }
                .task(id: model.notes) { await rebuild() }
                .onChange(of: [showLinks, showSources, showSimilar]) { relayout() }
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        TimelineView(.animation(paused: layout.isSettled)) { timeline in
            Canvas { ctx, size in draw(&ctx, size) } symbols: {
                ForEach(graph?.nodes.filter(\.isHub) ?? []) { NoteIcon(note: $0.note, size: 40).tag($0.id) }
            }
            .onChange(of: timeline.date) { tick() }
        }
        .drawingGroup()
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .simultaneousGesture(pinchGesture)
        .onTapGesture { p in
            if let i = hit(p) { activate(i) } else { focusedHub = nil }
        }
        .onContinuousHover { phase in
            guard drag == nil else { return }
            let i: Int? = if case .active(let p) = phase { hit(p) } else { nil }
            if i != hovered { hovered = i }
        }
        .pointerStyle(drag != nil ? .grabActive : hovered != nil ? .link : nil)
        .background(ScrollZoom { delta, p in
            autoFit = false
            camera = camera.zoomed(by: exp(delta * 0.01), around: p, in: size)
        })
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
        let center = hovered ?? focusedHub.flatMap { placed.firstIndex(of: $0) }
        let lit: Set<Int>? = center.map { c in
            shown.reduce(into: [c]) { set, e in if e.a == c { set.insert(e.b) } else if e.b == c { set.insert(e.a) } }
        }
        let query = filter.trimmingCharacters(in: .whitespaces)
        let dim = points.indices.map { i in
            !(lit?.contains(i) ?? true) || !query.isEmpty && !nodes[i].title.localizedCaseInsensitiveContains(query)
        }
        let boost = contrast == .increased ? 1.8 : 1

        // One stroke per edge kind and state (normal, dimmed, highlighted), however many edges there are.
        for kind in Graph.Edge.Kind.allCases {
            var paths = [Path(), Path(), Path()]
            for e in shown where e.kind == kind {
                let state = if let center { e.a == center || e.b == center ? 2 : 1 } else { dim[e.a] || dim[e.b] ? 1 : 0 }
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
        var glow = ctx  // only the hovered node and its neighbors glow, so the blur stays cheap
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
            if let icon = hub.resolveSymbol(id: nodes[i].id) {
                hub.draw(icon, in: rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2))
            }
        }

        // Labels fade in as you zoom, like Obsidian; hubs and the hovered node's neighbors always have one.
        let fade = min(max((camera.scale - 0.85) / 0.25, 0), 1)
        let onScreen = CGRect(origin: .zero, size: size).insetBy(dx: -80, dy: -40)
        for i in points.indices where i != center && !dim[i] && onScreen.contains(points[i]) {
            let opacity = nodes[i].isHub || lit != nil ? 1 : fade
            guard opacity > 0.25 else { continue }  // fainter reads as a smudge, not a label
            var label = ctx
            label.opacity = opacity
            if nodes[i].isHub || lit != nil { label.addFilter(.shadow(color: surface, radius: 2)) }  // a halo over busy edges; few labels, so cheap
            label.draw(Text(Self.short(nodes[i].title)).font(nodes[i].isHub ? .caption.weight(.semibold) : .caption)
                        .foregroundStyle(lit != nil ? .primary : .secondary),
                       at: CGPoint(x: points[i].x, y: points[i].y + screenRadius(i) + 2), anchor: .top)
        }

        if let center {
            let node = nodes[center]
            let detail = node.isHub ? "\(degree[center]) notes" : node.note.place
            let tip = ctx.resolve(Text(node.title).font(.callout.weight(.semibold))
                                  + Text("\n" + detail).font(.caption).foregroundStyle(.secondary))
            let box = tip.measure(in: CGSize(width: 280, height: 120))
            let rect = CGRect(x: points[center].x - box.width / 2 - 8, y: points[center].y + screenRadius(center) + 6,
                              width: box.width + 16, height: box.height + 8)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(surface.opacity(0.95)))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 6), with: .color(.primary.opacity(0.15 * boost)), lineWidth: 0.5)
            ctx.draw(tip, in: rect.insetBy(dx: 8, dy: 4))
        }
    }

    private var accent: Color {
        colorScheme == .dark ? Color(red: 1, green: 0.839, blue: 0.039) : Color(red: 0.78, green: 0.541, blue: 0)
    }

    /// Hub and tooltip background: opaque, so edges don't show through.
    private var surface: Color { colorScheme == .dark ? Color(white: 0.2) : .white }

    private static func stroke(_ kind: Graph.Edge.Kind) -> StrokeStyle {
        switch kind {
        case .link: StrokeStyle(lineWidth: 1.4)
        case .source: StrokeStyle(lineWidth: 0.8)
        case .similar: StrokeStyle(lineWidth: 1, dash: [3, 3])
        }
    }

    private static func edgeOpacity(_ kind: Graph.Edge.Kind) -> Double {
        switch kind {
        case .link: 0.45
        case .source: 0.18
        case .similar: 0.22
        }
    }

    private static func short(_ title: String) -> String { title.count > 32 ? title.prefix(31) + "…" : title }

    /// Sized by connections, like Obsidian; hubs are bigger so their icon fits.
    private func screenRadius(_ i: Int) -> CGFloat {
        let d = CGFloat(degree[i]).squareRoot()
        let r = graph?.nodes[i].isHub == true ? min(12 + 1.5 * d, 22) : min(4 + 1.8 * d, 14)
        return max(r * camera.scale, 2)
    }

    private func disc(_ p: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r) }

    // MARK: Interaction

    private func hit(_ p: CGPoint) -> Int? {
        var best: (i: Int, d: CGFloat)?
        for (i, q) in layout.positions.enumerated() {
            let s = camera.screen(q, in: size), d = hypot(s.x - p.x, s.y - p.y)
            if d <= max(screenRadius(i), 6) + 3, d < best?.d ?? .infinity { best = (i, d) }
        }
        return best?.i
    }

    private func activate(_ i: Int) {
        guard let node = graph?.nodes[i] else { return }
        if node.isHub { focusedHub = focusedHub == node.id ? nil : node.id } else { model.openRequest = node.id }
    }

    /// Drag a node to move it (the rest follow), or the background to pan.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if drag == nil {
                    autoFit = false
                    drag = hit(v.startLocation).map { .node($0) } ?? .pan(from: camera.offset)
                }
                switch drag {
                case .node(let i):
                    layout.pin(i, at: camera.world(v.location, in: size))
                    hovered = i
                case .pan(let start):
                    camera.offset = CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height)
                case nil: break
                }
            }
            .onEnded { _ in
                if case .node(let i) = drag { layout.unpin(i) }
                drag = nil
            }
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
        let notes = model.notes
        let built = await Task.detached(priority: .userInitiated) {
            Graph(notes: notes, vectors: NoteStore.vectors().mapValues(\.vector))
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
            case .similar: showSimilar
            }
        }
        let ids = graph.nodes.prefix(showSources ? graph.nodes.count : graph.noteCount).map(\.id)
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
        hovered = nil
        drag = nil  // its node index may point elsewhere now
        if reduceMotion, autoFit { fit() }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Filter", text: $filter, prompt: Text("Filter"))
                .textFieldStyle(.roundedBorder)
                .help("Dim notes whose title doesn't contain this")
            Toggle(isOn: $showLinks) { edgeLabel("Links", .link) }
                .help("Links between notes")
            Toggle(isOn: $showSources) { edgeLabel("Sources", .source) }
                .help("Each note joined to its app or website")
            Toggle(isOn: $showSimilar) { edgeLabel("Similar", .similar) }
                .help("Notes with a similar meaning")
            Button {
                autoFit = true
                fit()
            } label: {
                Label("Fit Graph", systemImage: "arrow.up.left.and.arrow.down.right").frame(maxWidth: .infinity)
            }
            .help("Center the graph and zoom to fit it")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .frame(width: 150)
        .padding(12)
        .floatingBackground()
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Graph settings")
    }

    /// The toggle's line style doubles as the legend, so kinds differ by more than color.
    private func edgeLabel(_ title: String, _ kind: Graph.Edge.Kind) -> some View {
        HStack(spacing: 6) {
            Path { $0.move(to: CGPoint(x: 0, y: 5)); $0.addLine(to: CGPoint(x: 18, y: 5)) }
                .stroke(.secondary, style: Self.stroke(kind))
                .frame(width: 18, height: 10)
                .accessibilityHidden(true)
            Text(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var noConnections: some View {
        VStack(spacing: 4) {
            Text("No Connections").font(.headline)
            Text(showLinks && showSources && showSimilar
                 ? "Link notes with [text](note://id), or keep writing: notes with a similar meaning join up once indexed."
                 : "Turn on Links, Sources or Similar to see how your notes connect.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
        .padding(12)
        .floatingBackground()
        .padding(16)
    }
}

/// Where the graph is on screen: `offset` is the graph origin's distance from the view's center.
private struct Camera {
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

/// SwiftUI has no scroll-wheel event for a plain view, so this watches the window's scrolls and takes the ones
/// over its own frame. It sits behind the canvas and lets clicks through.
private struct ScrollZoom: NSViewRepresentable {
    let onScroll: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> Monitor { Monitor() }
    func updateNSView(_ view: Monitor, context: Context) { view.onScroll = onScroll }

    final class Monitor: NSView {
        var onScroll: (CGFloat, CGPoint) -> Void = { _, _ in }
        private var monitor: Any?

        override var isFlipped: Bool { true }  // top-left origin, like SwiftUI
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = window == nil ? nil : NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let p = convert(event.locationInWindow, from: nil)
                guard bounds.contains(p) else { return event }
                onScroll(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10), p)  // a wheel notch is ~1
                return nil
            }
        }
    }
}
