using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using NoteAnywhere.Core;

namespace NoteAnywhere;

/// Alt+Shift+Space from any app: a Spotlight-style search over every note, as the Mac's SearchPopup. Words show at
/// once and the meaning-based ranking follows; Return opens the note in the notes window; Escape or a click elsewhere
/// closes it.
public partial class SearchPopup : Window
{
    readonly DispatcherTimer delay = new() { Interval = TimeSpan.FromMilliseconds(250) };

    public SearchPopup()
    {
        InitializeComponent();
        delay.Tick += async (_, _) => { delay.Stop(); await Run(); };
    }

    sealed record Row(Note Note)
    {
        public string Title => Note.Title;
        public string Preview => Note.Preview.Length == 0 ? "No additional text" : Note.Preview;
        public string Where => (Note.Kind == NoteKind.App ? $"App · {Note.Label}" : Note.HasSource ? $"Site · {Note.ShortSource()}" : "Note")
                               + " · " + NoteDates.Short(Note.Edited);
    }

    public void Toggle()
    {
        if (IsVisible) { Hide(); return; }
        Query.Text = "";
        Show();
        Activate();
        Query.Focus();
    }

    void OnQuery(object sender, RoutedEventArgs e)
    {
        var query = Query.Text.Trim();
        QueryHint.Visibility = Query.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        Hint.Visibility = query.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        Show(NoteActions.Search(NotesModel.Shared.Notes, query));  // words at once
        delay.Stop();
        if (query.Length > 0) delay.Start();
    }

    async Task Run()
    {
        var query = Query.Text.Trim();
        try
        {
            var notes = await NoteSearch.Search(query);
            if (Query.Text.Trim() == query) Show(notes);
        }
        catch (Exception e) { System.Diagnostics.Trace.WriteLine($"NoteAnywhere: search failed: {e.Message}"); }
    }

    void Show(List<Note> notes)
    {
        Results.ItemsSource = notes.Take(20).Select(n => new Row(n)).ToList();
        Results.SelectedIndex = notes.Count > 0 ? 0 : -1;
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Escape: Hide(); break;
            case Key.Down when Results.Items.Count > 0: Results.SelectedIndex = (Results.SelectedIndex + 1) % Results.Items.Count; break;
            case Key.Up when Results.Items.Count > 0: Results.SelectedIndex = (Results.SelectedIndex - 1 + Results.Items.Count) % Results.Items.Count; break;
            case Key.Enter: Open(); break;
            default: return;
        }
        Results.ScrollIntoView(Results.SelectedItem);
        e.Handled = true;
    }

    void OnOpen(object sender, MouseButtonEventArgs e) => Open();

    void Open()
    {
        if (Results.SelectedItem is not Row row) return;
        Hide();
        (Application.Current as App)?.OpenNote(row.Note.Id);
    }

    void OnDeactivated(object? sender, EventArgs e) => Hide();
}
