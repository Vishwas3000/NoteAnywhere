using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using NoteAnywhere.Core;

namespace NoteAnywhere;

/// The knowledge graph of all notes, like Obsidian's, as the Mac's GraphView: each note is a dot joined to its app or
/// site, to the notes it links to, to its #tags and to notes with a similar meaning. Click a note to open it, a hub to
/// highlight its notes; drag a dot to move it (the rest follow) or the background to pan; the wheel or a pinch zooms.
public partial class GraphView : UserControl
{
    static readonly FontFamily Icons = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    readonly NotesModel model = NotesModel.Shared;
    Graph? graph;
    // What the toggles show, kept in step: positions, node ids by index (to keep positions across rebuilds), the shown
    // edges and each node's number of them.
    GraphLayout layout = new(0, []);
    List<string> placed = [];
    List<Graph.Edge> shown = [];
    int[] degree = [];
    Camera camera = new();
    bool autoFit = true, stale = true, animating, panning;  // autoFit: follow the settling graph until the user pans, zooms or drags
    int builds;
    int? hovered, dragged;
    string? focusedHub;
    (Point At, Camera From)? press;
    TimeSpan lastFrame;

    public GraphView()
    {
        InitializeComponent();
        Plot.Draw = Draw;
        Plot.MouseLeftButtonDown += OnPress;
        Plot.MouseMove += OnMove;
        Plot.MouseLeftButtonUp += OnRelease;
        Plot.LostMouseCapture += (_, _) => EndDrag();
        Plot.MouseLeave += (_, _) => { if (press is null && hovered != null) { hovered = null; Plot.InvalidateVisual(); } };
        Plot.MouseWheel += OnWheel;
        Plot.SizeChanged += (_, _) => { if (autoFit) Fit(); };
        model.Changed += () => { if (IsVisible) Rebuild(); else stale = true; };
        Appearance.Changed += Plot.InvalidateVisual;
        IsVisibleChanged += (_, _) =>
        {
            if (!IsVisible) return;
            if (stale) Rebuild();
            else Animate();
        };
    }

    // Building

    async void Rebuild()
    {
        stale = false;
        var build = ++builds;
        var notes = model.Notes;
        bool sources = Sources.IsChecked == true, tags = Tags.IsChecked == true;
        NoNotes.Visibility = notes.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        Toggles.Visibility = notes.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        var built = await Task.Run(() => new Graph(notes, NoteStore.Vectors().ToDictionary(v => v.Key, v => v.Value.Vector), sources, tags));
        if (build != builds) return;  // a newer build is on its way
        graph = built;
        Relayout();
    }

    /// Lays out what the toggles show; nodes already on screen stay where they are.
    void Relayout()
    {
        if (graph is null) return;
        EndDrag();  // its node's index may point elsewhere now
        var edges = graph.Edges.Where(e => (e.Kind switch
        {
            Graph.EdgeKind.Link => Links,
            Graph.EdgeKind.Source => Sources,
            Graph.EdgeKind.Tag => Tags,
            _ => Similar,
        }).IsChecked == true).ToList();
        var ids = graph.Nodes.Select(n => n.Id).ToList();
        Dictionary<string, (double X, double Y)> old = [];
        for (var i = 0; i < placed.Count; i++) old.TryAdd(placed[i], layout.Positions[i]);
        layout = GraphLayout.Continuing(ids, edges, old);
        placed = ids;
        shown = edges;
        degree = new int[ids.Count];
        foreach (var e in edges) { degree[e.A]++; degree[e.B]++; }
        hovered = null;
        if (!SystemParameters.ClientAreaAnimation)  // Windows' "Animation effects" off, as the Mac's Reduce Motion: at rest at once
        {
            layout.Settle();
            if (autoFit) Fit();
        }
        NoConnectionsHint.Text = new[] { Links, Sources, Tags, Similar }.All(t => t.IsChecked == true)
            ? "Type #tags in your notes, link notes with [text](note://id), or keep writing: similar notes join up once indexed."
            : "Turn on Links, Sources, Tags or Similar to see how your notes connect.";
        NoConnections.Visibility = edges.Count == 0 && graph.NoteCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        Animate();
        Plot.InvalidateVisual();
    }

    void OnEdges(object sender, RoutedEventArgs e) => Relayout();
    void OnHubs(object sender, RoutedEventArgs e) => Rebuild();  // hubs that are off aren't built

    void OnFilter(object sender, TextChangedEventArgs e)
    {
        FilterHint.Visibility = Filter.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        Plot.InvalidateVisual();
    }

    void OnFit(object sender, RoutedEventArgs e)
    {
        autoFit = true;
        Fit();
    }

    void Fit()
    {
        camera = Fitting();
        Plot.InvalidateVisual();
    }

    /// The camera that fits the graph beside the controls, which float over the right of the view and would hide a corner of it.
    Camera Fitting()
    {
        var beside = Toggles.IsVisible ? Toggles.ActualWidth + Toggles.Margin.Left + Toggles.Margin.Right : 0;
        var fit = Camera.Fitting(layout.Positions, Plot.ActualWidth - beside, Plot.ActualHeight);
        return fit with { OffsetX = fit.OffsetX - beside / 2 };
    }

    // Moving

    void Animate()
    {
        if (animating || layout.IsSettled || !IsVisible) return;
        animating = true;
        CompositionTarget.Rendering += OnFrame;
    }

    void OnFrame(object? sender, EventArgs e)
    {
        if (e is RenderingEventArgs frame)
        {
            if (frame.RenderingTime == lastFrame) return;  // Rendering can come twice in one frame
            lastFrame = frame.RenderingTime;
        }
        if (layout.IsSettled || !IsVisible)
        {
            CompositionTarget.Rendering -= OnFrame;
            animating = false;
            return;
        }
        layout.Step();
        if (autoFit) camera = camera.Approaching(Fitting());
        Plot.InvalidateVisual();
    }

    void OnPress(object sender, MouseButtonEventArgs e)
    {
        press = (e.GetPosition(Plot), camera);
        Plot.CaptureMouse();
    }

    /// Drag a node to move it (the rest follow), or the background to pan; without the button, what's under the pointer lights up.
    void OnMove(object sender, MouseEventArgs e)
    {
        var p = e.GetPosition(Plot);
        if (press is { } start)
        {
            if (dragged is null && !panning)
            {
                if ((p - start.At).Length < 2) return;  // still a click
                autoFit = false;
                if (Hit(start.At) is { } i) dragged = i;
                else panning = true;
            }
            if (dragged is { } node)
            {
                layout.Pin(node, camera.World((p.X, p.Y), Plot.ActualWidth, Plot.ActualHeight));
                hovered = node;
                Animate();
            }
            else camera = camera with { OffsetX = start.From.OffsetX + p.X - start.At.X, OffsetY = start.From.OffsetY + p.Y - start.At.Y };
            Plot.InvalidateVisual();
        }
        else if (Hit(p) is var under && under != hovered)
        {
            hovered = under;
            Plot.InvalidateVisual();
        }
        Plot.Cursor = dragged != null || panning ? Cursors.SizeAll : hovered != null ? Cursors.Hand : null;
    }

    void OnRelease(object sender, MouseButtonEventArgs e)
    {
        if (press is null) return;
        var click = dragged is null && !panning;
        EndDrag();
        if (!click) return;
        if (Hit(e.GetPosition(Plot)) is { } i) Activate(i);
        else if (focusedHub != null)
        {
            focusedHub = null;
            Plot.InvalidateVisual();
        }
    }

    void EndDrag()
    {
        if (dragged is { } node) layout.Unpin(node);
        dragged = null;
        panning = false;
        press = null;
        if (Plot.IsMouseCaptured) Plot.ReleaseMouseCapture();
    }

    void OnWheel(object sender, MouseWheelEventArgs e)
    {
        autoFit = false;
        var p = e.GetPosition(Plot);
        camera = camera.Zoomed(Math.Exp(e.Delta / 120.0 * 0.1), (p.X, p.Y), Plot.ActualWidth, Plot.ActualHeight);  // 10% a notch, as on the Mac
        Plot.InvalidateVisual();
        e.Handled = true;
    }

    /// A note opens; a hub highlights its notes until it's clicked again or the background is.
    void Activate(int i)
    {
        var node = graph!.Nodes[i];
        if (!node.IsHub)
        {
            (Application.Current as App)?.OpenNote(node.Id);
            return;
        }
        focusedHub = focusedHub == node.Id ? null : node.Id;
        Plot.InvalidateVisual();
    }

    int? Hit(Point p)
    {
        int? best = null;
        var nearest = double.PositiveInfinity;
        for (var i = 0; i < layout.Positions.Count; i++)
        {
            var d = (Screen(layout.Positions[i]) - p).Length;
            if (d <= Math.Max(Radius(i), 6) + 3 && d < nearest) (best, nearest) = (i, d);
        }
        return best;
    }

    Point Screen((double X, double Y) p)
    {
        var (x, y) = camera.Screen(p, Plot.ActualWidth, Plot.ActualHeight);
        return new Point(x, y);
    }

    /// Sized by connections, like Obsidian; hubs are bigger so their mark fits.
    double Radius(int i)
    {
        var d = Math.Sqrt(degree[i]);
        var r = graph!.Nodes[i].IsHub ? Math.Min(12 + 1.5 * d, 22) : Math.Min(4 + 1.8 * d, 14);
        return Math.Max(r * camera.Scale, 2);
    }

    // Drawing

    void Draw(DrawingContext dc)
    {
        if (graph is null || placed.Count == 0) return;
        var nodes = graph.Nodes;
        var points = layout.Positions.Select(Screen).ToArray();
        int? center = hovered ?? (focusedHub != null && placed.IndexOf(focusedHub) is var hub and >= 0 ? hub : null);
        HashSet<int>? lit = center is { } c ? [c, .. shown.Where(e => e.A == c || e.B == c).Select(e => e.A == c ? e.B : e.A)] : null;
        var query = Filter.Text.Trim();
        var dim = points.Select((_, i) => lit != null && !lit.Contains(i)
            || query.Length > 0 && !nodes[i].Title.Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToArray();
        var dark = Appearance.IsDark;
        var ink = dark ? Colors.White : Colors.Black;  // the Mac's .primary
        var secondary = Fade(ink, 0.6);
        var accent = Appearance.Accent;
        var surface = dark ? Color.FromRgb(0x33, 0x33, 0x33) : Colors.White;  // hubs and the tip: opaque, so edges don't show through
        var family = TextElement.GetFontFamily(Plot);

        // One geometry per edge kind and state (normal, dimmed, highlighted), however many edges there are.
        int State(Graph.Edge e) => center is { } middle ? (e.A == middle || e.B == middle ? 2 : 1) : dim[e.A] || dim[e.B] ? 1 : 0;
        foreach (var kind in Enum.GetValues<Graph.EdgeKind>())
        {
            var edges = shown.Where(e => e.Kind == kind).ToList();
            dc.DrawGeometry(null, EdgePen(kind, Fade(ink, EdgeOpacity(kind))), Lines(edges.Where(e => State(e) == 0), points));
            dc.DrawGeometry(null, EdgePen(kind, Fade(ink, 0.05)), Lines(edges.Where(e => State(e) == 1), points));
            dc.DrawGeometry(null, EdgePen(kind, accent, 0.6), Lines(edges.Where(e => State(e) == 2), points));
        }

        var bright = Brush(accent);
        var faint = Brush(Fade(accent, 0.2));
        var glow = new RadialGradientBrush(Fade(accent, 0.6), Fade(accent, 0));  // only the hovered node and its neighbours glow
        glow.Freeze();
        for (var i = 0; i < points.Length; i++)
        {
            if (nodes[i].IsHub) continue;
            var r = Radius(i);
            if (dim[i])
            {
                dc.DrawEllipse(faint, null, points[i], r, r);
                continue;
            }
            if (lit != null) dc.DrawEllipse(glow, null, points[i], r + 6, r + 6);
            dc.DrawEllipse(bright, null, points[i], r, r);
        }
        if (center is { } ringed && !nodes[ringed].IsHub) dc.DrawEllipse(null, new Pen(bright, 2), points[ringed], Radius(ringed) + 3, Radius(ringed) + 3);

        for (var i = 0; i < points.Length; i++)
        {
            if (!nodes[i].IsHub) continue;
            var r = Radius(i);
            if (dim[i]) dc.PushOpacity(0.25);
            dc.DrawEllipse(Brush(surface), new Pen(Brush(i == center ? accent : Fade(ink, 0.25)), i == center ? 2 : 1), points[i], r, r);
            var mark = nodes[i].IsTag
                ? Text("#", r, FontWeights.Bold, accent, family)
                : Text(nodes[i].Note.Kind == NoteKind.App ? "" : "", r * 1.1, FontWeights.Normal, secondary, Icons);  // the sidebar's app and site marks
            dc.DrawText(mark, new Point(points[i].X - mark.Width / 2, points[i].Y - mark.Height / 2));
            if (dim[i]) dc.Pop();
        }

        // Labels fade in as you zoom, like Obsidian; hubs and the hovered node's neighbours always have one.
        var fade = Math.Clamp((camera.Scale - 0.85) / 0.25, 0, 1);
        var onScreen = new Rect(-80, -40, Plot.ActualWidth + 160, Plot.ActualHeight + 80);
        var halo = new Pen(Brush(surface), 3) { LineJoin = PenLineJoin.Round };
        for (var i = 0; i < points.Length; i++)
        {
            if (i == center || dim[i] || !onScreen.Contains(points[i])) continue;
            var opacity = nodes[i].IsHub || lit != null ? 1 : fade;
            if (opacity <= 0.25) continue;  // fainter reads as a smudge, not a label
            var label = Text(Short(nodes[i].Title), 11, nodes[i].IsHub ? FontWeights.SemiBold : FontWeights.Normal, lit != null ? ink : secondary, family);
            var origin = new Point(points[i].X - label.Width / 2, points[i].Y + Radius(i) + 2);
            dc.PushOpacity(opacity);
            if (nodes[i].IsHub || lit != null) dc.DrawGeometry(null, halo, label.BuildGeometry(origin));  // a halo over busy edges; few labels, so cheap
            dc.DrawText(label, origin);
            dc.Pop();
        }

        if (center is { } tipped)
        {
            var node = nodes[tipped];
            var detail = node.IsHub ? (degree[tipped] == 1 ? "1 note" : $"{degree[tipped]} notes") : NoteActions.Place(node.Note);
            var tip = Text(detail.Length > 0 ? node.Title + "\n" + detail : node.Title, 12, FontWeights.Normal, secondary, family);
            tip.MaxTextWidth = 280;
            tip.SetFontSize(13, 0, node.Title.Length);
            tip.SetFontWeight(FontWeights.SemiBold, 0, node.Title.Length);
            tip.SetForegroundBrush(Brush(ink), 0, node.Title.Length);
            var box = new Rect(points[tipped].X - tip.Width / 2 - 8, points[tipped].Y + Radius(tipped) + 6, tip.Width + 16, tip.Height + 8);
            dc.DrawRoundedRectangle(Brush(Fade(surface, 0.95)), new Pen(Brush(Fade(ink, 0.15)), 0.5), box, 6, 6);
            dc.DrawText(tip, new Point(box.X + 8, box.Y + 4));
        }
    }

    static StreamGeometry Lines(IEnumerable<Graph.Edge> edges, Point[] points)
    {
        var geometry = new StreamGeometry();
        using (var context = geometry.Open())
            foreach (var e in edges)
            {
                context.BeginFigure(points[e.A], false, false);
                context.LineTo(points[e.B], true, false);
            }
        geometry.Freeze();
        return geometry;
    }

    /// The Mac's line per kind of edge, which the toggles show as their legend: links solid, sources thin, tags dotted, similar dashed.
    static Pen EdgePen(Graph.EdgeKind kind, Color color, double wider = 0)
    {
        (double Width, double[]? Dashes) style = kind switch
        {
            Graph.EdgeKind.Link => (1.4, null),
            Graph.EdgeKind.Source => (0.8, null),
            Graph.EdgeKind.Tag => (1.2, new[] { 0.5, 3.5 }),
            _ => (1.0, new[] { 3.0, 3.0 }),
        };
        var width = style.Width + wider;
        var pen = new Pen(Brush(color), width) { DashCap = kind == Graph.EdgeKind.Tag ? PenLineCap.Round : PenLineCap.Flat };
        if (style.Dashes != null) pen.DashStyle = new DashStyle(style.Dashes.Select(d => d / width), 0);  // WPF counts dashes in line widths
        pen.Freeze();
        return pen;
    }

    static double EdgeOpacity(Graph.EdgeKind kind) => kind switch
    {
        Graph.EdgeKind.Link => 0.45,
        Graph.EdgeKind.Source => 0.18,
        Graph.EdgeKind.Tag => 0.4,
        _ => 0.22,
    };

    static string Short(string title)
    {
        var text = new StringInfo(title);  // whole characters, so an emoji is never cut in half
        return text.LengthInTextElements > 32 ? text.SubstringByTextElements(0, 31) + "…" : title;
    }

    FormattedText Text(string text, double size, FontWeight weight, Color color, FontFamily family) =>
        new(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, new Typeface(family, FontStyles.Normal, weight, FontStretches.Normal),
            size, Brush(color), VisualTreeHelper.GetDpi(Plot).PixelsPerDip);

    static Color Fade(Color color, double opacity) => Color.FromArgb((byte)Math.Round(opacity * color.A), color.R, color.G, color.B);

    static SolidColorBrush Brush(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }
}

/// What GraphView draws on, through Draw; it takes the mouse everywhere, for panning.
sealed class GraphCanvas : FrameworkElement
{
    public Action<DrawingContext>? Draw;

    public GraphCanvas() => ClipToBounds = true;

    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize));
        Draw?.Invoke(dc);
    }
}
