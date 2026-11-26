using System.Text.RegularExpressions;

namespace NoteAnywhere.Core;

// A port of Sources/MemoryNotes/GraphLayout.swift: the graph, its layout and the camera over it. GraphView draws them.

/// The knowledge graph: a node per note, a hub per app or site and per #tag, and four kinds of edges.
/// Notes come first in `Nodes`, hubs after them; hubs that are switched off aren't built at all.
public sealed partial class Graph
{
    /// `Id` is the note's id, or "app:bundle.id" / "url:host" / "tag:name" for a hub, whose `Note` is its first note.
    public sealed record Node(string Id, string Title, Note Note)
    {
        public bool IsHub => Id != Note.Id;
        public bool IsTag => Id.StartsWith("tag:", StringComparison.Ordinal);
    }

    public enum EdgeKind { Link, Source, Tag, Similar }

    public readonly record struct Edge(int A, int B, EdgeKind Kind);

    /// MiniLM cosine from which two notes count as related (unrelated pairs sit below ~0.25).
    public const float Similarity = 0.5f;
    /// Most similar-meaning edges per note, strongest first, so the graph doesn't turn into a hairball.
    public const int SimilarPerNote = 3;

    public List<Node> Nodes { get; } = [];
    public List<Edge> Edges { get; } = [];
    public int NoteCount { get; }

    public Graph(IReadOnlyList<Note> notes, IReadOnlyDictionary<string, float[]> vectors, bool sources = true, bool tags = true)
    {
        Nodes.AddRange(notes.Select(n => new Node(n.Id, n.Title, n)));
        NoteCount = notes.Count;
        Dictionary<string, int> index = [];
        for (var i = 0; i < notes.Count; i++) index.TryAdd(notes[i].Id, i);
        HashSet<(int, int)> paired = [];

        for (var i = 0; i < notes.Count; i++)
            foreach (Match match in NoteLink.Matches(notes[i].Text))
            {
                // Lowercased: links written before D76 hold uppercase ids.
                if (!index.TryGetValue(match.Groups[1].Value.ToLowerInvariant(), out var j) || j == i || !paired.Add((Math.Min(i, j), Math.Max(i, j)))) continue;
                Edges.Add(new(Math.Min(i, j), Math.Max(i, j), EdgeKind.Link));
            }

        Dictionary<string, int> hubs = [];
        if (sources)
            for (var i = 0; i < notes.Count; i++)
            {
                var note = notes[i];
                var key = note.Target.Split('/')[0];  // bundle id or host, like the Mac's IconStore
                if (key.Length == 0) continue;
                var id = $"{note.Kind.RawValue}:{key}";
                if (!hubs.TryGetValue(id, out var hub))
                {
                    hubs[id] = hub = Nodes.Count;
                    Nodes.Add(new(id, note.Kind == NoteKind.App && note.Label.Length > 0 ? note.Label : key, note));
                }
                Edges.Add(new(i, hub, EdgeKind.Source));
            }

        // Like Obsidian: a hub per tag, and a nested tag hangs off its parent (#project/notes → #project).
        int TagHub(string tag, Note note)
        {
            if (hubs.TryGetValue("tag:" + tag, out var hub)) return hub;
            hubs["tag:" + tag] = hub = Nodes.Count;
            Nodes.Add(new("tag:" + tag, "#" + tag, note));
            if (tag.LastIndexOf('/') is var slash and >= 0) Edges.Add(new(hub, TagHub(tag[..slash], note), EdgeKind.Tag));
            return hub;
        }
        if (tags)
            for (var i = 0; i < notes.Count; i++)
                foreach (var tag in notes[i].Tags) Edges.Add(new(i, TagHub(tag, notes[i]), EdgeKind.Tag));

        // Strongest pairs first; a pair is kept only while both notes have room, so no note gets more than SimilarPerNote.
        var embedded = Enumerable.Range(0, notes.Count).Where(i => vectors.ContainsKey(notes[i].Id)).Select(i => (I: i, V: vectors[notes[i].Id])).ToList();
        List<(float Score, int A, int B)> candidates = [];
        for (var x = 0; x < embedded.Count; x++)
            for (var y = x + 1; y < embedded.Count; y++)
            {
                var (i, u) = embedded[x];
                var (j, v) = embedded[y];
                if (u.Length != v.Length || paired.Contains((i, j))) continue;
                var score = Dot(u, v);  // vectors are normalized, so this is the cosine
                if (score >= Similarity) candidates.Add((score, i, j));
            }
        var count = new int[notes.Count];
        foreach (var c in candidates.OrderByDescending(c => c.Score))
        {
            if (count[c.A] >= SimilarPerNote || count[c.B] >= SimilarPerNote) continue;
            Edges.Add(new(c.A, c.B, EdgeKind.Similar));
            count[c.A]++;
            count[c.B]++;
        }
    }

    static float Dot(float[] a, float[] b)
    {
        var sum = 0f;  // in Float, as the Mac's vDSP.dot
        for (var i = 0; i < a.Length; i++) sum += a[i] * b[i];
        return sum;
    }

    [GeneratedRegex("note://([0-9A-Fa-f-]+)")]
    private static partial Regex NoteLink { get; }
}

/// Force-directed layout after d3-force: repulsion between all nodes, springs along edges, a gentle pull to the
/// center and velocity damping. Forces scale with `Alpha`, which cools toward zero, so the simulation always comes to
/// rest. No randomness: the same nodes, edges and start always give the same positions.
public sealed class GraphLayout
{
    public const double Repulsion = 150, CenterPull = 0.03, Damping = 0.4, AlphaMin = 0.001;
    public static readonly double AlphaDecay = 1 - Math.Pow(AlphaMin, 1.0 / 300);  // ~300 steps (5 s at 60 fps) from hot to rest

    /// Rest length and stiffness per edge kind: explicit links pull hardest, similar meaning least.
    public static (double Length, double Strength) Spring(Graph.EdgeKind kind) => kind switch
    {
        Graph.EdgeKind.Link => (60, 1),
        Graph.EdgeKind.Source => (50, 1),
        Graph.EdgeKind.Tag => (55, 0.8),
        _ => (70, 0.15),
    };

    readonly record struct Rope(int A, int B, double Length, double Strength, double Bias);

    readonly (double X, double Y)[] positions, velocities;
    readonly Rope[] springs;
    readonly Dictionary<int, (double X, double Y)> pinned = [];
    double alphaTarget;

    public double Alpha { get; set; } = 1;
    public bool IsSettled => Alpha < AlphaMin;
    public IReadOnlyList<(double X, double Y)> Positions => positions;

    /// Nodes missing from `start` begin on a sunflower spiral, which spreads them evenly without randomness.
    public GraphLayout(int count, IReadOnlyList<Graph.Edge> edges, IReadOnlyDictionary<int, (double X, double Y)>? start = null)
    {
        positions = new (double, double)[count];
        for (var i = 0; i < count; i++)
        {
            if (start != null && start.TryGetValue(i, out var p)) { positions[i] = p; continue; }
            double r = 10 * Math.Sqrt(0.5 + i), angle = i * Math.PI * (3 - Math.Sqrt(5));
            positions[i] = (r * Math.Cos(angle), r * Math.Sin(angle));
        }
        velocities = new (double, double)[count];
        var degree = new int[count];
        foreach (var e in edges) { degree[e.A]++; degree[e.B]++; }
        // Like d3: a spring is softer on busy nodes, and the busier end (a hub) moves less.
        springs = [.. edges.Select(e =>
        {
            var (length, strength) = Spring(e.Kind);
            return new Rope(e.A, e.B, length, strength / Math.Min(degree[e.A], degree[e.B]), (double)degree[e.A] / (degree[e.A] + degree[e.B]));
        })];
    }

    /// A layout for what the toggles show (`edges` over the nodes `ids`) in which nodes already on screen (`placed`, by
    /// id) stay where they are; a new node starts on a placed neighbour, e.g. a hub on one of its notes.
    public static GraphLayout Continuing(IReadOnlyList<string> ids, IReadOnlyList<Graph.Edge> edges, IReadOnlyDictionary<string, (double X, double Y)> placed)
    {
        Dictionary<int, (double X, double Y)> start = [];
        for (var i = 0; i < ids.Count; i++) if (placed.TryGetValue(ids[i], out var p)) start[i] = p;
        var kept = start.Count;
        foreach (var e in edges)
        {
            if (!start.ContainsKey(e.A) && start.TryGetValue(e.B, out var b)) start[e.A] = b;
            else if (!start.ContainsKey(e.B) && start.TryGetValue(e.A, out var a)) start[e.B] = a;
        }
        var layout = new GraphLayout(ids.Count, edges, start);
        if (kept > ids.Count / 2) layout.Alpha = 0.3;  // mostly placed: settle gently instead of starting over
        return layout;
    }

    public void Step()
    {
        Alpha += (alphaTarget - Alpha) * AlphaDecay;
        foreach (var s in springs)
        {
            var dx = positions[s.B].X + velocities[s.B].X - positions[s.A].X - velocities[s.A].X;
            var dy = positions[s.B].Y + velocities[s.B].Y - positions[s.A].Y - velocities[s.A].Y;
            if (dx == 0 && dy == 0) (dx, dy) = Jiggle(s.A, s.B);
            var l = Math.Sqrt(dx * dx + dy * dy);
            var f = (l - s.Length) / l * Alpha * s.Strength;
            velocities[s.B].X -= dx * f * s.Bias;
            velocities[s.B].Y -= dy * f * s.Bias;
            velocities[s.A].X += dx * f * (1 - s.Bias);
            velocities[s.A].Y += dy * f * (1 - s.Bias);
        }
        // shortcut: O(n²) repulsion is fine for a few hundred notes; use a Barnes-Hut quadtree beyond ~1,000.
        for (var i = 0; i < positions.Length; i++)
            for (var j = i + 1; j < positions.Length; j++)
            {
                var dx = positions[j].X - positions[i].X;
                var dy = positions[j].Y - positions[i].Y;
                if (dx == 0 && dy == 0) (dx, dy) = Jiggle(i, j);
                var f = Repulsion * Alpha / Math.Max(dx * dx + dy * dy, 1);
                velocities[i].X -= dx * f;
                velocities[i].Y -= dy * f;
                velocities[j].X += dx * f;
                velocities[j].Y += dy * f;
            }
        for (var i = 0; i < positions.Length; i++)
        {
            if (pinned.TryGetValue(i, out var p))
            {
                positions[i] = p;
                velocities[i] = default;
                continue;
            }
            velocities[i].X = (velocities[i].X - positions[i].X * CenterPull * Alpha) * (1 - Damping);
            velocities[i].Y = (velocities[i].Y - positions[i].Y * CenterPull * Alpha) * (1 - Damping);
            positions[i].X += velocities[i].X;
            positions[i].Y += velocities[i].Y;
        }
    }

    public void Settle()
    {
        for (var n = 0; n < 1000 && !IsSettled; n++) Step();
    }

    /// Holds a node under the pointer and keeps the rest warm so they follow, like dragging in Obsidian.
    public void Pin(int i, (double X, double Y) p)
    {
        pinned[i] = p;
        positions[i] = p;
        alphaTarget = 0.3;
        Alpha = Math.Max(Alpha, 0.3);
    }

    public void Unpin(int i)
    {
        pinned.Remove(i);
        alphaTarget = 0;
    }

    /// Nodes on the same spot have no direction to push apart in; nudge them a tiny, repeatable way.
    static (double, double) Jiggle(int i, int j)
    {
        double angle = i * 7 + j;
        return (Math.Cos(angle) * 1e-3, Math.Sin(angle) * 1e-3);
    }
}

/// Where the graph is on screen: the offset is the graph origin's distance from the view's center.
public sealed record Camera(double Scale = 1, double OffsetX = 0, double OffsetY = 0)
{
    public (double X, double Y) Screen((double X, double Y) p, double width, double height) =>
        (width / 2 + OffsetX + p.X * Scale, height / 2 + OffsetY + p.Y * Scale);

    public (double X, double Y) World((double X, double Y) p, double width, double height) =>
        ((p.X - width / 2 - OffsetX) / Scale, (p.Y - height / 2 - OffsetY) / Scale);

    /// Keeps the graph point under `p` where it is.
    public Camera Zoomed(double factor, (double X, double Y) p, double width, double height)
    {
        var s = Math.Min(Math.Max(Scale * factor, 0.1), 5);
        var k = s / Scale;
        double x = p.X - width / 2, y = p.Y - height / 2;
        return new(s, x - (x - OffsetX) * k, y - (y - OffsetY) * k);
    }

    public static Camera Fitting(IReadOnlyList<(double X, double Y)> points, double width, double height)
    {
        if (points.Count == 0 || width <= 0 || height <= 0) return new();
        double minX = points.Min(p => p.X), maxX = points.Max(p => p.X), minY = points.Min(p => p.Y), maxY = points.Max(p => p.Y);
        const double margin = 60;  // room for node radii and labels
        var s = Math.Min((width - 2 * margin) / Math.Max(maxX - minX, 1), (height - 2 * margin) / Math.Max(maxY - minY, 1));
        var scale = Math.Min(Math.Max(s, 0.1), 1.5);
        return new(scale, -(minX + maxX) / 2 * scale, -(minY + maxY) / 2 * scale);
    }

    /// A step of the way there, so following the settling graph is smooth.
    public Camera Approaching(Camera target)
    {
        const double k = 0.15;
        return new(Scale + (target.Scale - Scale) * k, OffsetX + (target.OffsetX - OffsetX) * k, OffsetY + (target.OffsetY - OffsetY) * k);
    }
}
