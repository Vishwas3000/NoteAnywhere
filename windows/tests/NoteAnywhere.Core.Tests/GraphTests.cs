namespace NoteAnywhere.Core.Tests;

/// Tests/MemoryNotesTests/GraphTests.swift, and more: the reference positions are what the Mac's GraphLayout.swift returned.
public class GraphTests
{
    static Note N(string id, string target = "", NoteKind kind = NoteKind.Url, string label = "", string text = "") =>
        new() { Id = id, Kind = kind, Target = target, Label = label, Text = text };

    static double Distance((double X, double Y) p, (double X, double Y) q) => Math.Sqrt((p.X - q.X) * (p.X - q.X) + (p.Y - q.Y) * (p.Y - q.Y));

    static Graph.Edge E(int a, int b, Graph.EdgeKind kind) => new(a, b, kind);

    static readonly Dictionary<string, float[]> NoVectors = [];

    [Fact]
    public void LinkEdgesAreUndirectedAndSkipMissingNotes()
    {
        var a = N("a1", text: "See [b](note://b2), again note://b2, a gone note://ff and myself note://a1");
        var b = N("b2", text: "Back to [a](note://A1)");  // an id in capitals, as links held before D76
        var c = N("c3", text: "[c](note://c3)");
        Assert.Equal([E(0, 1, Graph.EdgeKind.Link)], new Graph([a, b, c], NoVectors).Edges);
    }

    [Fact]
    public void NotesShareOneHubPerAppOrHost()
    {
        Note[] notes =
        [
            N("a1", "com.tinyspeck.slackmacgap/Acme/Alex Rivera (DM)", NoteKind.App, "Slack"),
            N("b2", "com.tinyspeck.slackmacgap", NoteKind.App, "Slack"),
            N("c3", "github.com/vercel/next.js"),
            N("d4", "github.com"),
            N("e5"),  // a new website note without an address yet
        ];
        var graph = new Graph(notes, NoVectors);
        Assert.Equal(5, graph.NoteCount);
        Assert.Equal(["Slack", "github.com"], graph.Nodes.Skip(5).Select(n => n.Title));
        Assert.Equal([false, false, false, false, false, true, true], graph.Nodes.Select(n => n.IsHub));
        Assert.Equal([E(0, 5, Graph.EdgeKind.Source), E(1, 5, Graph.EdgeKind.Source), E(2, 6, Graph.EdgeKind.Source), E(3, 6, Graph.EdgeKind.Source)], graph.Edges);
        Assert.Equal(["app:com.tinyspeck.slackmacgap", "url:github.com"], graph.Nodes.Skip(5).Select(n => n.Id));
    }

    /// The center note is similar (0.9, 0.8, 0.7, 0.6) to four others: all pass the threshold, but it keeps only its
    /// three strongest. Unrelated and unembedded notes get nothing.
    [Fact]
    public void SimilarityKeepsTopKAboveThreshold()
    {
        static float[] Near(float cos, int axis)
        {
            var v = new float[6];
            v[0] = cos;
            v[axis] = MathF.Sqrt(1 - cos * cos);
            return v;
        }
        string[] ids = ["c0", "a1", "a2", "a3", "a4", "f5", "e6"];
        Dictionary<string, float[]> vectors = new()
        {
            ["c0"] = [1, 0, 0, 0, 0, 0], ["a1"] = Near(0.9f, 1), ["a2"] = Near(0.8f, 2), ["a3"] = Near(0.7f, 3),
            ["a4"] = Near(0.6f, 4), ["f5"] = [0, 0, 0, 0, 0, 1],  // e6 has no vector yet
        };
        var graph = new Graph([.. ids.Select(id => N(id))], vectors);
        var similar = graph.Edges.Where(e => e.Kind == Graph.EdgeKind.Similar).ToList();
        HashSet<int> Neighbors(int i) => [.. similar.Where(e => e.A == i || e.B == i).Select(e => e.A == i ? e.B : e.A)];
        Assert.Equal([1, 2, 3], Neighbors(0).Order());
        Assert.Empty(Neighbors(5));
        Assert.Empty(Neighbors(6));
        Assert.All(Enumerable.Range(0, 7), i => Assert.True(Neighbors(i).Count <= Graph.SimilarPerNote));
        Assert.All(similar, e => Assert.True(vectors[ids[e.A]].Zip(vectors[ids[e.B]]).Sum(p => p.First * p.Second) >= 0.5 - 1e-6));
    }

    [Fact]
    public void LinkedNotesAreNotAlsoSimilar()
    {
        var graph = new Graph([N("a1", text: "note://b2"), N("b2")], new Dictionary<string, float[]> { ["a1"] = [1, 0], ["b2"] = [1, 0] });
        Assert.Equal([E(0, 1, Graph.EdgeKind.Link)], graph.Edges);
    }

    [Fact]
    public void NotesSharingATagMeetAtItsHub()
    {
        Note[] notes = [N("a1", text: "#ml basics"), N("b2", text: "more #ML and #project/notes"), N("c3", text: "none")];
        var graph = new Graph(notes, NoVectors, sources: false);
        Assert.Equal(["#ml", "#project/notes", "#project"], graph.Nodes.Skip(3).Select(n => n.Title));
        Assert.All(graph.Nodes.Skip(3), n => Assert.True(n.IsTag && n.IsHub));
        Assert.Equal(new HashSet<Graph.Edge>
        {
            E(0, 3, Graph.EdgeKind.Tag), E(1, 3, Graph.EdgeKind.Tag),
            E(1, 4, Graph.EdgeKind.Tag), E(4, 5, Graph.EdgeKind.Tag),  // nested tag under its parent
        }, graph.Edges.ToHashSet());
        Assert.Equal(3, new Graph(notes, NoVectors, sources: false, tags: false).Nodes.Count);
    }

    [Fact]
    public void LockedNotesShowNoTags()
    {
        var graph = new Graph([N("a1", text: "#secret") with { Locked = true }], NoVectors);
        Assert.Equal(["Locked Note"], graph.Nodes.Select(n => n.Title));
        Assert.Empty(graph.Edges);
    }

    [Fact]
    public void ConnectedNodesEndCloserThanUnconnected()
    {
        var layout = new GraphLayout(6, [E(0, 1, Graph.EdgeKind.Link), E(2, 3, Graph.EdgeKind.Similar)]);
        for (var n = 0; n < 300; n++) layout.Step();
        var p = layout.Positions;
        Assert.True(Distance(p[0], p[1]) < Distance(p[0], p[2]));
        Assert.True(Distance(p[0], p[1]) < Distance(p[0], p[4]));
        Assert.True(Distance(p[2], p[3]) < Distance(p[2], p[5]));
    }

    [Fact]
    public void SimulationSettles()
    {
        List<Graph.Edge> edges = [.. Enumerable.Range(1, 39).Select(i => E(0, i, Graph.EdgeKind.Source)), E(1, 2, Graph.EdgeKind.Link)];
        var layout = new GraphLayout(40, edges);
        layout.Settle();
        Assert.True(layout.IsSettled);
        var before = layout.Positions.ToList();
        layout.Step();
        Assert.All(before.Zip(layout.Positions), p => Assert.True(Distance(p.First, p.Second) < 0.1));
    }

    [Fact]
    public void OverlappingNodesSeparateWithoutNaN()
    {
        var start = Enumerable.Range(0, 4).ToDictionary(i => i, _ => (5.0, 5.0));
        var layout = new GraphLayout(4, [E(0, 1, Graph.EdgeKind.Link), E(2, 3, Graph.EdgeKind.Source)], start);
        for (var n = 0; n < 50; n++) layout.Step();
        Assert.All(layout.Positions, p => Assert.True(double.IsFinite(p.X) && double.IsFinite(p.Y)));
        Assert.True(Distance(layout.Positions[0], layout.Positions[1]) > 1);
    }

    [Fact]
    public void PinnedNodeStaysUnderThePointer()
    {
        var layout = new GraphLayout(3, [E(0, 1, Graph.EdgeKind.Link)]);
        layout.Pin(0, (400, -300));
        for (var n = 0; n < 100; n++) layout.Step();
        Assert.Equal((400.0, -300.0), layout.Positions[0]);
        Assert.False(layout.IsSettled);  // kept warm while dragging
        layout.Unpin(0);
        layout.Settle();
        Assert.True(layout.IsSettled);
    }

    static readonly Graph.Edge[] Mixed =
    [
        E(0, 1, Graph.EdgeKind.Link), E(0, 2, Graph.EdgeKind.Source), E(1, 2, Graph.EdgeKind.Source), E(3, 2, Graph.EdgeKind.Source),
        E(4, 5, Graph.EdgeKind.Tag), E(5, 6, Graph.EdgeKind.Similar), E(6, 7, Graph.EdgeKind.Link), E(2, 7, Graph.EdgeKind.Tag),
    ];

    /// Printed by the Mac's GraphLayout.swift for the same edges: 100 steps, then at rest (after 300), then the camera that fits 800 × 600.
    [Fact]
    public void PositionsMatchTheMacs()
    {
        (double X, double Y)[] after100 =
        [
            (56.022545624559669, 9.3145290495102682), (0.8604381518799028, 62.55732822130517), (-6.1459976684010336, 1.850930654898157),
            (35.014776385323465, 42.202460707894382), (29.457111407050846, -149.1798621145272), (21.058213002411225, -89.692061596698721),
            (-105.14106529740961, 15.251509634502588), (-66.286660935646537, -34.579094414056954),
        ];
        (double X, double Y)[] atRest =
        [
            (54.535407578601571, 12.034640583255394), (0.059196201520883424, 66.416353951441849), (-7.0746583424272611, 6.4362686216978817),
            (34.54454657922755, 45.910164752463935), (31.247007947866294, -148.36072443598781), (10.366987356726689, -91.730369021605625),
            (-111.35866394382451, 9.8542262266473344), (-65.198400409216973, -32.645952807394046),
        ];
        var layout = new GraphLayout(8, Mixed);
        for (var n = 0; n < 100; n++) layout.Step();
        Assert.All(after100.Zip(layout.Positions), p => Assert.True(Distance(p.First, p.Second) < 1e-6, $"{p.First} vs {p.Second}"));
        var steps = 100;
        for (; !layout.IsSettled; steps++) layout.Step();
        Assert.Equal(300, steps);
        Assert.All(atRest.Zip(layout.Positions), p => Assert.True(Distance(p.First, p.Second) < 1e-6, $"{p.First} vs {p.Second}"));
        var camera = Camera.Fitting(layout.Positions, 800, 600);
        Assert.Equal(1.5, camera.Scale);
        Assert.Equal(42.617442273917206, camera.OffsetX, 1e-6);
        Assert.Equal(61.458277863409464, camera.OffsetY, 1e-6);
    }

    [Fact]
    public void TheSameGraphLaysOutTheSameWay()
    {
        var one = new GraphLayout(8, Mixed);
        var two = new GraphLayout(8, Mixed);
        one.Settle();
        two.Settle();
        Assert.Equal(one.Positions, two.Positions);  // to the last bit
    }

    [Fact]
    public void NodesOnScreenStayWhereTheyAre()
    {
        List<Graph.Edge> edges = [E(0, 1, Graph.EdgeKind.Link), E(0, 2, Graph.EdgeKind.Source)];
        Dictionary<string, (double X, double Y)> placed = new() { ["a"] = (10, 20), ["b"] = (-30, 5) };
        var layout = GraphLayout.Continuing(["a", "b", "url:hub"], edges, placed);
        Assert.Equal([(10.0, 20.0), (-30.0, 5.0), (10.0, 20.0)], layout.Positions);  // the new hub starts on its note
        Assert.Equal(0.3, layout.Alpha);  // mostly placed: settles gently
        Assert.Equal(1, GraphLayout.Continuing(["a", "x", "y"], edges, placed).Alpha);  // mostly new: starts over
    }

    [Fact]
    public void ZoomingKeepsThePointUnderThePointer()
    {
        var camera = new Camera(1.2, 30, -10);
        var world = camera.World((250, 140), 800, 600);
        Assert.Equal((250.0, 140.0), Round(camera.Screen(world, 800, 600)));
        var zoomed = camera.Zoomed(2, (250, 140), 800, 600);
        Assert.Equal(2.4, zoomed.Scale, 1e-9);
        Assert.Equal((250.0, 140.0), Round(zoomed.Screen(world, 800, 600)));
        Assert.Equal(5, camera.Zoomed(100, (0, 0), 800, 600).Scale);  // never closer than 5×
        Assert.Equal(0.1, camera.Zoomed(0.001, (0, 0), 800, 600).Scale);  // nor further than a tenth
        static (double, double) Round((double X, double Y) p) => (Math.Round(p.X, 9), Math.Round(p.Y, 9));
    }

    [Fact]
    public void TheCameraFitsAndFollows()
    {
        var fit = Camera.Fitting([(-100, -50), (100, 50)], 800, 600);
        Assert.Equal(1.5, fit.Scale);  // no closer than 1.5×, however small the graph
        Assert.Equal((400.0, 300.0), fit.Screen((0, 0), 800, 600));  // the graph's middle in the view's
        Assert.Equal(new Camera(), Camera.Fitting([], 800, 600));
        var step = new Camera().Approaching(new Camera(2, 100, -100));
        Assert.Equal(new Camera(1.15, 15, -15), step with { Scale = Math.Round(step.Scale, 9), OffsetX = Math.Round(step.OffsetX, 9), OffsetY = Math.Round(step.OffsetY, 9) });
    }
}
