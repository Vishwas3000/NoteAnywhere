using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using NoteAnywhere.Core;

namespace NoteAnywhere;

/// Notes, Calendar or Graph on the right, as the Mac's toolbar switch: Ctrl+1, Ctrl+2 and Ctrl+3 for its ⌘1–⌘3. Opening
/// a note, here or from elsewhere, goes back to Notes. `--view calendar` (or graph, month, week, day) opens on a view,
/// for CI's screenshots.
public partial class MainWindow
{
    void AddViews()
    {
        RadioButton[] tabs = [NotesTab, CalendarTab, GraphTab];
        for (var i = 0; i < tabs.Length; i++)
        {
            var tab = tabs[i];
            InputBindings.Add(new KeyBinding(new Command(() => tab.IsChecked = true), Key.D1 + i, ModifierKeys.Control));
        }
        Sidebar.SelectionChanged += (_, _) => { if (!rebuilding && Sidebar.SelectedItem is NoteItem) NotesTab.IsChecked = true; };
        var args = Environment.GetCommandLineArgs();
        var view = Array.IndexOf(args, "--view") is var at and >= 0 && at + 1 < args.Length ? args[at + 1] : "notes";
        if (Enum.TryParse<NoteCalendar.Mode>(view, ignoreCase: true, out var mode))
        {
            CalendarPane.Show(mode);
            view = "calendar";
        }
        (view == "calendar" ? CalendarTab : view == "graph" ? GraphTab : NotesTab).IsChecked = true;
    }

    void OnViewChecked(object sender, RoutedEventArgs e)
    {
        NotesPane.Visibility = Shown(NotesTab);
        CalendarPane.Visibility = Shown(CalendarTab);
        GraphPane.Visibility = Shown(GraphTab);
        DeleteButton.Visibility = NotesPane.Visibility;  // the Mac's toolbar has Delete only beside a note
        static Visibility Shown(RadioButton tab) => tab.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }
}
