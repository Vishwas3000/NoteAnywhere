using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using NoteAnywhere.Core;
using Mode = NoteAnywhere.Core.NoteCalendar.Mode;

namespace NoteAnywhere;

/// What's planned and what was edited when, as the Mac's CalendarView: month, week and day views of the notes' dated
/// lines (tasks first under "Planned", with a circle that ticks them in their note; ranges as strips in their colour)
/// and of the notes edited each day (the store's daily snapshots). Clicking a day opens it; an event or an edited
/// note in the day view opens its note.
public partial class CalendarView : UserControl
{
    static readonly Geometry Check = Geometry.Parse("M3.8,7.3 L6.1,9.6 L10.3,4.7");
    static readonly Brush GridLine = new SolidColorBrush(Color.FromArgb(0x22, 0x80, 0x80, 0x80)), CardFill = new SolidColorBrush(Color.FromArgb(0x1A, 0x80, 0x80, 0x80));

    readonly NotesModel model = NotesModel.Shared;
    readonly ContextMenu eventMenu = new();
    Mode mode = Mode.Month;
    DateOnly date = Today;
    bool stale = true, shortcuts;
    CultureInfo culture = CultureInfo.CurrentCulture;
    string? datePattern;
    Dictionary<string, List<DatedLine>> due = [];
    Dictionary<string, List<Snapshot>> edited = [];

    static DateOnly Today => DateOnly.FromDateTime(DateTime.Now);
    DayOfWeek First => culture.DateTimeFormat.FirstDayOfWeek;
    FontFamily Icons => (FontFamily)Resources["Icons"];

    public CalendarView()
    {
        InitializeComponent();
        MonthMode.IsChecked = true;
        model.Changed += Refresh;
        Appearance.Changed += Refresh;
        IsVisibleChanged += (_, _) => { if (IsVisible && stale) Render(); };
        Loaded += (_, _) => AddShortcuts();
    }

    /// Today in `mode`, for `--view week` and `--view day`.
    public void Show(Mode mode) => Show(Today, mode);

    void Show(DateOnly day, Mode m)
    {
        date = day;
        mode = m;
        (m == Mode.Day ? DayMode : m == Mode.Week ? WeekMode : MonthMode).IsChecked = true;
        Refresh();
    }

    void Refresh()
    {
        if (IsVisible) Render();
        else stale = true;
    }

    void Step(int n)
    {
        date = NoteCalendar.Step(date, mode, n);
        Refresh();
    }

    void OnPrevious(object sender, RoutedEventArgs e) => Step(-1);
    void OnNext(object sender, RoutedEventArgs e) => Step(1);
    void OnToday(object sender, RoutedEventArgs e) => Show(Today, mode);

    void OnMode(object sender, RoutedEventArgs e)
    {
        var m = sender == DayMode ? Mode.Day : sender == WeekMode ? Mode.Week : Mode.Month;
        if (m == mode) return;
        mode = m;
        Refresh();
    }

    /// Ctrl+Left, Ctrl+T and Ctrl+Right for the Mac's ⌘←, ⌘T and ⌘→. On the window, so they work wherever the focus is
    /// while the calendar shows; a text box keeps Ctrl+arrows for moving by words.
    void AddShortcuts()
    {
        if (shortcuts || Window.GetWindow(this) is not { } window) return;
        shortcuts = true;
        window.PreviewKeyDown += (_, e) =>
        {
            if (!IsVisible || Keyboard.Modifiers != ModifierKeys.Control) return;
            switch (e.Key)
            {
                case Key.T: Show(Today, mode); break;
                case Key.Left or Key.Right when e.OriginalSource is not TextBoxBase: Step(e.Key == Key.Left ? -1 : 1); break;
                default: return;
            }
            e.Handled = true;
        };
    }

    void Render()
    {
        stale = false;
        culture = CultureInfo.CurrentCulture;
        datePattern = Settings.Load().DateFormat is { Length: > 0 } pattern ? pattern : null;
        due = DatedLine.ByDay(model.Notes.SelectMany(n => n.Dates));
        edited = NoteStore.LoadHistory().GroupBy(s => s.Day).ToDictionary(day => day.Key, day => day.ToList());
        Heading.Text = NoteCalendar.Title(date, mode, culture);
        var unit = mode.ToString().ToLowerInvariant();
        PreviousButton.ToolTip = $"Previous {unit} (Ctrl+Left)";
        NextButton.ToolTip = $"Next {unit} (Ctrl+Right)";
        Body.Content = due.Count == 0 && edited.Count == 0
            ? Empty("Nothing Here Yet", "Notes appear on the days you edit them. Type @today or @tomorrow in a note to put a line or task on a day.")
            : mode switch { Mode.Month => Month(), Mode.Week => Week(), _ => Day() };
    }

    List<DatedLine> Due(DateOnly day) => due.GetValueOrDefault(NoteCalendar.Key(day)) ?? [];
    List<Snapshot> Edited(DateOnly day) => edited.GetValueOrDefault(NoteCalendar.Key(day)) ?? [];

    // Month

    UIElement Month()
    {
        var names = new UniformGrid { Columns = 7, Margin = new Thickness(0, 4, 0, 4) };
        foreach (var name in NoteCalendar.WeekdayNames(culture))
            names.Children.Add(Secondary(new TextBlock { Text = name, FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center }));
        // Always 6 rows, so the grid doesn't jump in height between months.
        var cells = new UniformGrid { Columns = 7, Rows = 6 };
        foreach (var day in NoteCalendar.Days(date, Mode.Month, First)) cells.Children.Add(MonthCell(day));
        return new DockPanel { Children = { Docked(names, Dock.Top), new Border { BorderBrush = GridLine, BorderThickness = new Thickness(0, 1, 0, 0), Child = cells } } };
    }

    UIElement MonthCell(DateOnly day)
    {
        List<DatedLine> planned = Due(day);
        List<Snapshot> notes = Edited(day);
        var (lines, shown, more) = NoteCalendar.MonthCell(planned, notes);
        var list = new StackPanel { Margin = new Thickness(6), Opacity = day.Month == date.Month ? 1 : 0.35 };
        list.Children.Add(DayNumber(day));
        foreach (var item in lines) list.Children.Add(Spaced(item.IsRange ? Strip(item, day, 6) : Pill(item), 3));
        foreach (var s in shown)
            list.Children.Add(Spaced(Secondary(new TextBlock { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, Inlines = { Glyph(s.Note, 11), new Run(" " + s.Note.Title) } }), 3));
        if (more > 0) list.Children.Add(Spaced(Secondary(new TextBlock { Text = $"{more} more", FontSize = 12 }), 3));
        var cell = Plain(list, () => Show(day, Mode.Day), $"{day.ToString("D", culture)}, {planned.Count} planned, {notes.Count} notes edited");
        return new Border { BorderBrush = GridLine, BorderThickness = new Thickness(0, 0, 1, 1), ClipToBounds = true, Child = cell };
    }

    /// A planned line in a month cell: a tinted pill, so planned days stand apart from notes merely edited that day.
    FrameworkElement Pill(DatedLine item)
    {
        var row = new DockPanel { Children = { Docked(Box(item, 12), Dock.Left), Words(item, 12) } };
        return WithMenu(new Border { Background = Tint(item, 0.3), CornerRadius = new CornerRadius(4), Padding = new Thickness(4, 1, 4, 1), Child = row }, item);
    }

    /// The day of the month; today's sits in an accent circle, with dark text so it reads on the yellow in both modes.
    FrameworkElement DayNumber(DateOnly day)
    {
        var today = day == Today;
        var number = new TextBlock
        {
            Text = day.Day.ToString(culture), FontSize = 13, FontWeight = today ? FontWeights.SemiBold : FontWeights.Normal,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        };
        if (today) number.Foreground = Brushes.Black;
        return new Border
        {
            Width = 22, Height = 22, CornerRadius = new CornerRadius(11), HorizontalAlignment = HorizontalAlignment.Left,
            Background = today ? new SolidColorBrush(Appearance.Accent) : null, Child = number,
        };
    }

    // Week

    UIElement Week()
    {
        var days = NoteCalendar.Days(date, Mode.Week, First);
        // Ranges touching the week go in rows shared by every column, so a strip lines up from day to day.
        var rows = NoteCalendar.RangeRows(days.SelectMany(Due));
        var grid = new Grid();
        for (var i = 0; i < days.Count; i++)
        {
            var day = days[i];
            var key = NoteCalendar.Key(day);
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            var header = new StackPanel { Orientation = Orientation.Horizontal };
            header.Children.Add(Secondary(new TextBlock { Text = day.ToString("ddd", culture), FontSize = 13, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 4, 0) }));
            header.Children.Add(DayNumber(day));
            var column = new DockPanel { Margin = new Thickness(8), LastChildFill = true };
            column.Children.Add(Docked(Plain(header, () => Show(day, Mode.Day), "Open " + day.ToString("D", culture)), Dock.Top));
            foreach (var row in rows)
            {
                var item = row.FirstOrDefault(r => string.CompareOrdinal(r.First, key) <= 0 && string.CompareOrdinal(key, r.Last) <= 0);
                FrameworkElement strip = item is null
                    ? Strip(row[0], day, 8)  // hidden, it keeps the row, so the strips below stay level
                    : Plain(Strip(item, day, 8), () => OpenNote(item.NoteID), help: "Opens the note");
                if (item is null) strip.Visibility = Visibility.Hidden;
                column.Children.Add(Docked(Spaced(strip, 8), Dock.Top));
            }
            var list = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
            foreach (var item in Due(day).Where(d => !d.IsRange)) list.Children.Add(PlannedRow(item, compact: true));
            foreach (var s in Edited(day)) list.Children.Add(Plain(Card(s), () => Show(day, Mode.Day), s.Note.Title));
            column.Children.Add(new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
            var cell = new Border { BorderBrush = GridLine, BorderThickness = new Thickness(0, 0, 1, 0), Child = column };  // under the strips, which run across it
            Grid.SetColumn(cell, i);
            grid.Children.Add(cell);
        }
        if (days.All(d => Due(d).Count == 0 && Edited(d).Count == 0))
        {
            var empty = Empty("Nothing This Week", "Notes you edit or plan for this week appear here.");
            Grid.SetColumnSpan(empty, days.Count);
            grid.Children.Add(empty);
        }
        return grid;
    }

    FrameworkElement Card(Snapshot s)
    {
        var card = new StackPanel();
        card.Children.Add(Lines(new TextBlock { Text = s.Note.Title, FontSize = 13, FontWeight = FontWeights.SemiBold }, 2));
        if (s.Note.Preview.Length > 0) card.Children.Add(Spaced(Secondary(Lines(new TextBlock { Text = s.Note.Preview, FontSize = 12 }, 2)), 3));
        if (s.Note.HasSource)
            card.Children.Add(Spaced(Tertiary(new TextBlock { FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis, Inlines = { Glyph(s.Note, 10), new Run(" " + s.Note.ShortSource()) } }), 3));
        return new Border { Child = card, Padding = new Thickness(8), CornerRadius = new CornerRadius(8), Background = CardFill, Margin = new Thickness(0, 0, 0, 6) };
    }

    // Day

    UIElement Day()
    {
        List<DatedLine> planned = Due(date);
        List<Snapshot> notes = Edited(date);
        if (planned.Count == 0 && notes.Count == 0)
            return Empty("Nothing on This Day", "Notes you edit on this day, and lines dated for it, appear here.");
        var list = new StackPanel { Margin = new Thickness(24, 4, 24, 24) };
        if (planned.Count > 0)
        {
            list.Children.Add(Section("Planned"));
            foreach (var item in planned) list.Children.Add(PlannedRow(item, compact: false));
        }
        if (notes.Count > 0)
        {
            list.Children.Add(Section("Edited"));
            foreach (var s in notes)
            {
                var row = new StackPanel { Margin = new Thickness(2, 6, 2, 6) };
                row.Children.Add(new TextBlock { Text = s.Note.Title, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
                var preview = new Run("  " + (s.Note.Preview.Length == 0 ? "No additional text" : s.Note.Preview));
                preview.SetResourceReference(TextElement.ForegroundProperty, "TextFillColorSecondaryBrush");
                row.Children.Add(new TextBlock
                {
                    FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 3, 0, 0),
                    Inlines = { new Run(s.Note.Edited.ToLocalTime().ToString("t", culture)), preview },
                });
                list.Children.Add(Plain(row, () => OpenNote(s.Note.Id), s.Note.Title, "Opens the note"));
            }
        }
        return new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    // Planned lines

    /// A dated line with its task circle, its words (which open the note), its dates if it's a range, and its note's
    /// title when that says something else; a tinted card in the week's columns.
    FrameworkElement PlannedRow(DatedLine item, bool compact)
    {
        var note = model.Find(item.NoteID);
        var words = new StackPanel();
        var text = Words(item, compact ? 13 : 14);
        text.TextWrapping = TextWrapping.Wrap;
        words.Children.Add(compact ? Lines(text, 3) : text);
        if (item.IsRange) words.Children.Add(Secondary(new TextBlock { Text = Span(item), FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis }));
        if (note != null && note.Title != item.Text) words.Children.Add(Secondary(new TextBlock { Text = note.Title, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis }));
        var row = new DockPanel { Children = { Docked(Box(item, compact ? 13 : 15), Dock.Left), Plain(words, () => OpenNote(item.NoteID), help: "Opens the note") } };
        return WithMenu(new Border
        {
            Child = row, CornerRadius = new CornerRadius(8), Margin = new Thickness(0, 0, 0, 6),
            Padding = compact ? new Thickness(8) : new Thickness(2, 4, 2, 4), Background = compact ? Tint(item, 0.25) : null,
        }, item);
    }

    /// One day of a range: a tinted strip that runs into the next day's cell, rounded where the range starts and ends.
    FrameworkElement Strip(DatedLine item, DateOnly day, double inset)
    {
        var (starts, ends, titled) = NoteCalendar.Strip(item, day, First);
        var corners = new CornerRadius(starts ? 4 : 0, ends ? 4 : 0, ends ? 4 : 0, starts ? 4 : 0);
        var words = new TextBlock { Text = titled ? item.Text : " ", FontSize = 12, FontWeight = FontWeights.Medium, TextTrimming = TextTrimming.CharacterEllipsis, Padding = new Thickness(5, 1, 5, 1) };
        // Over the cell's padding to its edges (and its line), on the window's colour, so no grid line shows through.
        var strip = new Border
        {
            CornerRadius = corners, Margin = new Thickness(starts ? 0 : -inset, 0, ends ? 0 : -inset - 1, 0),
            Child = new Border { CornerRadius = corners, Background = Tint(item, 0.3), Child = words },
        };
        strip.SetResourceReference(Border.BackgroundProperty, "ApplicationBackgroundBrush");
        AutomationProperties.SetName(strip, $"{item.Text}, {Span(item)}");
        return WithMenu(strip, item);
    }

    /// "03/12/2026 – 06/12/2026", in the date format chosen in Settings.
    string Span(DatedLine item) => $"{DateStyle.Format(item.First ?? item.Day, datePattern)} – {DateStyle.Format(item.Last ?? item.Day, datePattern)}";

    /// A task's circle, which ticks it in its note; a calendar mark for other dated lines.
    FrameworkElement Box(DatedLine item, double size)
    {
        if (!item.IsTask)
            return new TextBlock { Text = "", FontFamily = Icons, FontSize = size - 1, Foreground = new SolidColorBrush(Swatch(item)), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 6, 0) };
        var mark = new Grid { Width = 14, Height = 14 };
        mark.Children.Add(new Ellipse { Margin = new Thickness(0.75), StrokeThickness = 1.5, Stroke = item.Done ? null : new SolidColorBrush(Swatch(item)), Fill = item.Done ? new SolidColorBrush(Appearance.Accent) : Brushes.Transparent });
        if (item.Done) mark.Children.Add(new Path { Data = Check, Stroke = Appearance.IsDark ? Brushes.Black : Brushes.White, StrokeThickness = 1.6, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round });
        var box = Plain(new Viewbox { Width = size, Height = size, Child = mark }, () => Edit(item, item.Ticked), item.Done ? "Done" : "Not done", "Ticks the task in its note");
        box.Margin = new Thickness(0, 2, 6, 0);
        box.VerticalAlignment = VerticalAlignment.Top;
        box.Cursor = Cursors.Hand;
        return box;
    }

    /// Ticking a task or colouring an event is a text edit, saved as typing is.
    void Edit(DatedLine item, Func<string, string> change)
    {
        if (model.Find(item.NoteID) is not { } note) return;
        model.SaveText(note.Id, change(note.Text));
        Render();
    }

    /// Right-click on an event: its own colour, written into its line of the note (D67). One menu, filled when it opens.
    T WithMenu<T>(T element, DatedLine item) where T : FrameworkElement
    {
        element.ContextMenu = eventMenu;
        element.ContextMenuOpening += (_, _) =>
        {
            var color = new MenuItem { Header = "Color" };
            color.Items.Add(MenuItem("None", item.Color != null, () => Edit(item, text => item.Recolored(text, null))));
            color.Items.Add(new Separator());
            foreach (var c in Enum.GetValues<NoteColor>())
                color.Items.Add(MenuItem(char.ToUpperInvariant(c.RawValue[0]) + c.RawValue[1..], item.Color != c, () => Edit(item, text => item.Recolored(text, c)),
                    new Ellipse { Width = 10, Height = 10, Fill = new SolidColorBrush(NoteItem.Swatch(c)) }));
            eventMenu.Items.Clear();
            eventMenu.Items.Add(color);
        };
        return element;
    }

    static MenuItem MenuItem(string header, bool enabled, Action run, object? icon = null)
    {
        var item = new MenuItem { Header = header, IsEnabled = enabled, Icon = icon };
        item.Click += (_, _) => run();
        return item;
    }

    Color Swatch(DatedLine item) => NoteItem.Swatch(item.BarColor(model.Find(item.NoteID)?.Color));

    Brush Tint(DatedLine item, double opacity)
    {
        var c = Swatch(item);
        return new SolidColorBrush(Color.FromArgb((byte)Math.Round(opacity * 255), c.R, c.G, c.B));
    }

    // Pieces

    static void OpenNote(string id) => (Application.Current as App)?.OpenNote(id);

    Button Plain(object content, Action click, string? name = null, string? help = null)
    {
        var button = new Button { Style = (Style)Resources["Plain"], Content = content };
        if (name != null) AutomationProperties.SetName(button, name);
        if (help != null) AutomationProperties.SetHelpText(button, help);
        button.Click += (_, _) => click();
        return button;
    }

    static TextBlock Words(DatedLine item, double size)
    {
        var text = new TextBlock { Text = item.Text, FontSize = size, TextTrimming = TextTrimming.CharacterEllipsis };
        if (!item.Done) return text;
        text.TextDecorations = TextDecorations.Strikethrough;
        return Secondary(text);
    }

    /// A website's globe, an app's window or a plain note's page, as the sidebar marks them.
    Run Glyph(Note note, double size) =>
        new(note.Kind == NoteKind.App ? "" : note.HasSource ? "" : "") { FontFamily = Icons, FontSize = size };

    static TextBlock Section(string title) =>
        Secondary(new TextBlock { Text = title, FontSize = 13, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 16, 0, 6) });

    static FrameworkElement Empty(string title, string description) => new StackPanel
    {
        VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = 380,
        Children =
        {
            new TextBlock { Text = title, FontSize = 20, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center },
            new TextBlock { Text = description, Opacity = 0.7, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 6, 0, 0) },
        },
    };

    /// At most `count` lines, the last one cut short with "…".
    static TextBlock Lines(TextBlock text, int count)
    {
        text.TextWrapping = TextWrapping.Wrap;
        text.TextTrimming = TextTrimming.CharacterEllipsis;
        text.MaxHeight = Math.Ceiling(count * text.FontSize * text.FontFamily.LineSpacing);
        return text;
    }

    static T Secondary<T>(T element) where T : FrameworkElement
    {
        element.SetResourceReference(TextElement.ForegroundProperty, "TextFillColorSecondaryBrush");
        return element;
    }

    static T Tertiary<T>(T element) where T : FrameworkElement
    {
        element.SetResourceReference(TextElement.ForegroundProperty, "TextFillColorTertiaryBrush");
        return element;
    }

    static T Docked<T>(T element, Dock dock) where T : UIElement
    {
        DockPanel.SetDock(element, dock);
        return element;
    }

    static T Spaced<T>(T element, double top) where T : FrameworkElement
    {
        element.Margin = new Thickness(element.Margin.Left, top, element.Margin.Right, element.Margin.Bottom);
        return element;
    }
}
