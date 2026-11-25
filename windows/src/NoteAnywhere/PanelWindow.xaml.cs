using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using NoteAnywhere.Core;
using NoteAnywhere.Editor;
using NoteAnywhere.Platform;

namespace NoteAnywhere;

/// The floating panel that follows the window in front, as the Mac's overlay: the notes of that app and place, each on a
/// card with its editor, newest first. It appears without taking the keyboard; clicking into a card lets you type.
public partial class PanelWindow : Window
{
    readonly NotesModel model = NotesModel.Shared;
    readonly Dictionary<string, Border> cards = [];
    FrontContext? context;
    bool placed;

    public PanelWindow()
    {
        InitializeComponent();
        model.Changed += Refresh;
    }

    public FrontContext? Context => context;

    public static List<Note> NotesFor(FrontContext c) =>
        NoteActions.Shown(NotesModel.Shared.Notes, c.Target, null, NoteActions.Browsers.Contains(c.AppId));

    /// Shows the place's notes; `takeFocus` (Alt+Shift+M) also puts the cursor in the newest note.
    public void ShowFor(FrontContext c, bool takeFocus)
    {
        if (context?.Target != c.Target) { Cards.Children.Clear(); cards.Clear(); }
        context = c;
        Refresh();
        if (!placed)
        {
            var area = SystemParameters.WorkArea;  // first time: the top-right corner, then wherever it's moved
            Left = area.Right - Width - 20;
            Top = area.Top + 20;
            placed = true;
        }
        if (!IsVisible) Show();
        if (takeFocus)
        {
            Activate();
            (Cards.Children.OfType<Border>().FirstOrDefault()?.Tag as EditorView)?.FocusEditor();
        }
    }

    void Refresh()
    {
        if (context is not { } c) return;
        Title = c.AppName;
        AppName.Text = c.AppName;
        var place = string.Join(" › ", c.Target.Split('/').Skip(1));
        PlaceLine.Text = place;
        PlaceLine.Visibility = place.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        var notes = NotesFor(c).OrderByDescending(n => n.UpdatedAt).Take(20).ToList();
        // Cards stay where they are while you type (moving one would rebuild its editor): new ones go on top, gone ones go.
        foreach (var gone in cards.Keys.Except(notes.Select(n => n.Id)).ToList())
        {
            Cards.Children.Remove(cards[gone]);
            cards.Remove(gone);
        }
        foreach (var note in notes.Where(n => !cards.ContainsKey(n.Id)).Reverse())
        {
            cards[note.Id] = Card(note);
            Cards.Children.Insert(0, cards[note.Id]);
        }
        Empty.Visibility = notes.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyNew.Content = $"New Note for {(place.Length > 0 ? place : c.AppName)}";
    }

    Border Card(Note note)
    {
        var editor = new EditorView { Page = false, NoteId = note.Id, Height = 120 };
        editor.OpenNote += id => (Application.Current as App)?.OpenNote(id);
        var open = new Button { Content = "", ToolTip = "Open in NoteAnywhere", Padding = new Thickness(6, 2, 6, 2) };
        var delete = new Button { Content = "", ToolTip = "Delete", Padding = new Thickness(6, 2, 6, 2), Margin = new Thickness(4, 0, 0, 0) };
        foreach (var b in new[] { open, delete }) { b.FontFamily = (FontFamily)FindResource("Icons"); b.Background = Brushes.Transparent; b.BorderThickness = new Thickness(0); }
        AutomationProperties(open, "Open in NoteAnywhere");
        AutomationProperties(delete, "Delete");
        open.Click += (_, _) => (Application.Current as App)?.OpenNote(note.Id);
        delete.Click += (_, _) =>
        {
            var current = model.Find(note.Id);
            if (current is null) return;
            if (MessageBox.Show(this, $"“{current.Title}” will be removed.", "Delete this note?", MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK)
                model.Delete(note.Id);
        };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Children = { open, delete } };
        DockPanel.SetDock(actions, Dock.Top);
        return new Border
        {
            Tag = editor,
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(6, 4, 6, 8),
            Margin = new Thickness(0, 0, 0, 10),
            BorderThickness = new Thickness(1),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x33, 0x80, 0x80, 0x80)),
            Child = new DockPanel { Children = { actions, editor } },
        };
        static void AutomationProperties(Button b, string name) => System.Windows.Automation.AutomationProperties.SetName(b, name);
    }

    void OnNewNote(object sender, RoutedEventArgs e)
    {
        if (context is not { } c) return;
        var note = model.Add(NoteKind.App, c.Target, c.AppName);
        Refresh();
        Activate();
        (cards.GetValueOrDefault(note.Id)?.Tag as EditorView)?.FocusEditor();
    }

    // Kept for the next time: closing only hides it.
    protected override void OnClosing(CancelEventArgs e)
    {
        e.Cancel = true;
        Hide();
    }
}
