using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using NoteAnywhere.Core;

namespace NoteAnywhere;

/// Every note in one place, as the Mac's NotesWindow after its cleanup (D84): a sidebar of folders, pinned notes, date
/// sections and tags, with the selected note's editor on the right.
public partial class MainWindow : Window
{
    readonly NotesModel model = NotesModel.Shared;
    readonly DispatcherTimer searchDelay = new() { Interval = TimeSpan.FromMilliseconds(250) };
    string? selected, folderFilter;
    (string Query, List<Note> Notes)? ranked;  // search by meaning's answer, once it arrives
    bool starredOnly, rebuilding;

    public MainWindow()
    {
        InitializeComponent();
        if (!WindowPlaces.Restore(this, "notes"))
        {
            // A small screen (or a 1024×768 test machine) gets a window that fits, centred.
            var area = SystemParameters.WorkArea;
            Width = Math.Min(Width, area.Width - 32);
            Height = Math.Min(Height, area.Height - 32);
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
        }

        model.Changed += Rebuild;
        searchDelay.Tick += async (_, _) =>
        {
            searchDelay.Stop();
            Rebuild();  // words at once; meaning when it's ready
            var query = SearchBox.Text.Trim();
            if (query.Length == 0) return;
            try
            {
                var notes = await NoteSearch.Search(query);
                if (SearchBox.Text.Trim() != query) return;
                ranked = (query, notes);
                Rebuild();
            }
            catch (Exception e) { System.Diagnostics.Trace.WriteLine($"NoteAnywhere: search failed: {e.Message}"); }
        };
        Editor.OpenNote += Open;
        Editor.SearchTag += tag => SearchBox.Text = "#" + tag;
        InputBindings.Add(new KeyBinding(new Command(NewNote), Key.N, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new Command(NewWebsiteNote), Key.N, ModifierKeys.Control | ModifierKeys.Shift));
        InputBindings.Add(new KeyBinding(new Command(() => { SearchBox.Focus(); SearchBox.SelectAll(); }), Key.F, ModifierKeys.Control | ModifierKeys.Alt));
        Rebuild();
        if (selected is null && model.Notes.Count > 0) Open(model.Notes.MaxBy(n => n.UpdatedAt)!.Id);
    }

    /// Opens a note: selects its row (leaving a folder or search that hides it) and shows it in the editor.
    public void Open(string id)
    {
        if (model.Find(id) is not { } note) return;
        if (folderFilter != null && note.FolderID != folderFilter) folderFilter = null;
        if (starredOnly && !note.Starred) starredOnly = false;
        selected = id;
        if (SearchBox.Text.Length > 0) SearchBox.Text = "";
        Rebuild();
        ShowNote();
    }

    IEnumerable<Note> Visible => model.Notes.Where(n => (folderFilter == null || n.FolderID == folderFilter) && (!starredOnly || n.Starred));

    void Rebuild()
    {
        var items = new List<SidebarItem>();
        var query = SearchBox.Text.Trim();
        SearchHint.Visibility = SearchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (query.Length > 0)
        {
            var hits = ranked is { } r && r.Query == query
                ? r.Notes.Select(n => model.Find(n.Id)).OfType<Note>().ToList()  // the ranking, with today's text
                : NoteActions.Search(model.Notes, query);
            items.Add(new HeaderItem(hits.Count == 1 ? "1 Result" : $"{hits.Count} Results"));
            items.AddRange(hits.Select(n => new NoteItem(n)));
        }
        else
        {
            items.Add(new HeaderItem("Folders"));
            items.Add(new FolderItem(null, "All Notes", model.Notes.Count, "", folderFilter == null && !starredOnly));
            items.Add(new FolderItem("starred", "Starred", model.Notes.Count(n => n.Starred), "", starredOnly));
            items.AddRange(model.Folders.Select(f => new FolderItem(f.Id, f.Name, model.Notes.Count(n => n.FolderID == f.Id), "", f.Id == folderFilter && !starredOnly)));
            var shown = Visible.ToList();
            var pinned = shown.Where(n => n.Pinned).OrderByDescending(n => n.UpdatedAt).ToList();
            if (pinned.Count > 0) { items.Add(new HeaderItem("Pinned")); items.AddRange(pinned.Select(n => new NoteItem(n))); }
            foreach (var section in NoteDates.Sections(shown.Where(n => !n.Pinned)))
            {
                items.Add(new HeaderItem(section.Title));
                items.AddRange(section.Notes.Select(n => new NoteItem(n)));
            }
            var tags = NoteActions.TagCounts(model.Notes);
            if (tags.Count > 0) { items.Add(new HeaderItem("Tags")); items.AddRange(tags.Select(t => new TagItem(t.Tag, t.Count))); }
        }
        rebuilding = true;
        Sidebar.ItemsSource = items;
        Sidebar.SelectedItem = items.OfType<NoteItem>().FirstOrDefault(i => i.Note.Id == selected);
        rebuilding = false;
        if (selected != null && model.Find(selected) is null) { selected = null; }
        ShowNote();
    }

    void ShowNote()
    {
        var note = selected is null ? null : model.Find(selected);
        NothingSelected.Visibility = note is null ? Visibility.Visible : Visibility.Collapsed;
        Editor.Visibility = note is null ? Visibility.Hidden : Visibility.Visible;
        DeleteButton.IsEnabled = note != null;
        Editor.NoteId = note?.Id;
        if (note is null) { SourceLine.Text = EditedLine.Text = ""; return; }
        SourceLine.Text = note.HasSource ? (note.Kind == NoteKind.Url ? "\U0001F310 " : "") + NoteActions.Place(note) : "";
        SourceLine.Visibility = note.HasSource ? Visibility.Visible : Visibility.Collapsed;
        var edited = note.Edited.ToLocalTime();
        EditedLine.Text = $"Edited {edited:d MMMM yyyy} at {edited:t}";
    }

    void OnSidebarSelection(object sender, SelectionChangedEventArgs e)
    {
        if (rebuilding) return;
        switch (Sidebar.SelectedItem)
        {
            case NoteItem item:
                selected = item.Note.Id;
                ShowNote();
                break;
            case FolderItem folder:
                starredOnly = folder.Id == "starred";
                folderFilter = starredOnly ? null : folder.Id;
                Rebuild();
                break;
            case TagItem tag:
                SearchBox.Text = "#" + tag.Tag;
                break;
        }
    }

    void OnSearchChanged(object sender, TextChangedEventArgs e)
    {
        searchDelay.Stop();
        searchDelay.Start();  // debounce typing
        if (SearchBox.Text.Trim().Length == 0) ranked = null;
        SearchHint.Visibility = SearchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    void OnSidebarKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Delete && Sidebar.SelectedItem is NoteItem item) { Delete(item.Note); e.Handled = true; }
    }

    void OnNewNote(object sender, RoutedEventArgs e) => NewNote();
    void OnDelete(object sender, RoutedEventArgs e) { if (selected != null && model.Find(selected) is { } note) Delete(note); }

    /// A note on its own, in the folder you're looking at; the editor takes the cursor.
    void NewNote()
    {
        var note = model.Add(NoteKind.Url, "", "", folderFilter, starred: starredOnly);
        Open(note.Id);
        Editor.FocusEditor();
    }

    void NewWebsiteNote()
    {
        if (Address(null) is not { } target) return;
        var note = model.Add(NoteKind.Url, target, target, folderFilter, starred: starredOnly);
        Open(note.Id);
        Editor.FocusEditor();
    }

    /// Asks for a page address and makes it the target the extension uses ("github.com/vercel/next.js"), or null.
    string? Address(string? current)
    {
        var typed = Prompt.Ask(this, "Add Website", "Page address, e.g. github.com/vercel/next.js", current ?? "", "Add");
        if (typed is null) return null;
        var target = Uri.TryCreate(typed.Contains("://") ? typed : "https://" + typed, UriKind.Absolute, out var url) ? Note.PageTarget(url) : "";
        if (target.Length == 0) MessageBox.Show(this, "That isn't a web page's address.", "Add Website");
        return target.Length > 0 ? target : null;
    }

    void Delete(Note note)
    {
        var message = note.Text.Length == 0 ? "This empty note will be removed." : $"“{note.Title}” will be removed.";
        if (MessageBox.Show(this, message, "Delete this note?", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        if (selected == note.Id) selected = null;
        model.Delete(note.Id);
    }

    void OnNewFolder(object sender, RoutedEventArgs e)
    {
        if (Prompt.Ask(this, "New Folder", "Name", "", "Create") is { } name) folderFilter = model.AddFolder(name).Id;
        starredOnly = false;
        Rebuild();
    }

    /// The right-click menu of the row under the pointer: Apple Notes' note menu (D84), or a folder's.
    void OnSidebarMenu(object sender, ContextMenuEventArgs e)
    {
        var row = ItemsControl.ContainerFromElement(Sidebar, (DependencyObject)e.OriginalSource) as ListBoxItem;
        var menu = Sidebar.ContextMenu!;
        menu.Items.Clear();
        switch (row?.DataContext)
        {
            case NoteItem { Note: var note }:
                Add(menu, note.Pinned ? "Unpin Note" : "Pin Note", () => model.Update(note.Id, n => n with { Pinned = !n.Pinned }));
                Add(menu, note.Starred ? "Unstar Note" : "Star Note", () => model.Update(note.Id, n => n with { Starred = !n.Starred }));
                menu.Items.Add(new Separator());
                Add(menu, "New Note", NewNote);
                Add(menu, "Duplicate Note", () => Open(model.Duplicate(note).Id), !note.Locked);
                menu.Items.Add(new Separator());
                var move = new MenuItem { Header = "Move to" };
                Add(move, "All Notes (No Folder)", () => model.Update(note.Id, n => n with { FolderID = null }), note.FolderID != null);
                if (model.Folders.Count > 0) move.Items.Add(new Separator());
                foreach (var folder in model.Folders)
                    Add(move, folder.Name, () => model.Update(note.Id, n => n with { FolderID = folder.Id }), note.FolderID != folder.Id);
                move.Items.Add(new Separator());
                Add(move, "New Folder…", () => { if (Prompt.Ask(this, "New Folder", "Name", "", "Create") is { } name) { var f = model.AddFolder(name); model.Update(note.Id, n => n with { FolderID = f.Id }); } });
                menu.Items.Add(move);
                var color = new MenuItem { Header = "Color" };
                Add(color, "None", () => model.Update(note.Id, n => n with { Color = null }), note.Color != null);
                color.Items.Add(new Separator());
                foreach (var c in Enum.GetValues<NoteColor>())
                    Add(color, char.ToUpperInvariant(c.RawValue[0]) + c.RawValue[1..], () => model.Update(note.Id, n => n with { Color = c }), note.Color != c);
                menu.Items.Add(color);
                if (note.Kind == NoteKind.Url)
                {
                    menu.Items.Add(new Separator());
                    if (note.HasSource)
                    {
                        Add(menu, "Open Page", () => Process.Start(new ProcessStartInfo("https://" + note.Target) { UseShellExecute = true }));
                        Add(menu, "Copy Link", () => Clipboard.SetText("https://" + note.Target));
                    }
                    else Add(menu, "Add Website…", () => { if (Address(null) is { } target) model.SetTarget(note.Id, target, target); });
                }
                menu.Items.Add(new Separator());
                Add(menu, "Delete", () => Delete(note));
                break;
            case FolderItem { Id: { } id } folder when id != "starred":
                Add(menu, "Rename…", () => { if (Prompt.Ask(this, "Rename Folder", "Name", folder.Name, "Rename") is { } name) model.RenameFolder(model.Folders.First(f => f.Id == id), name); });
                Add(menu, "Delete Folder", () => { if (folderFilter == id) folderFilter = null; model.DeleteFolder(id); });
                break;
            default:
                e.Handled = true;  // nothing to offer here
                break;
        }
    }

    static void Add(ItemsControl menu, string header, Action run, bool enabled = true)
    {
        var item = new MenuItem { Header = header, IsEnabled = enabled };
        item.Click += (_, _) => run();
        menu.Items.Add(item);
    }

    // The app stays in the notification area; closing the window hides it.
    protected override void OnClosing(CancelEventArgs e)
    {
        e.Cancel = true;
        Hide();
    }

    sealed class Command(Action run) : ICommand
    {
        public event EventHandler? CanExecuteChanged { add { } remove { } }
        public bool CanExecute(object? parameter) => true;
        public void Execute(object? parameter) => run();
    }
}
