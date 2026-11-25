using System.Windows;
using System.Windows.Controls;

namespace NoteAnywhere;

public partial class MainWindow : Window
{
    // Phase 0 (D86): sample notes in memory, to show the shared editor running; the store replaces them in phase 1.
    readonly List<string> notes =
    [
        "Welcome to NoteAnywhere for Windows\n\nThe same editor as on the Mac: **bold**, `code`, lists and checklists.\n\n- [x] The window opens\n- [ ] Notes are saved",
        "Release checklist\n#launch\n- [x] Sign the build\n- [ ] Update the website",
    ];

    public MainWindow()
    {
        InitializeComponent();
        // A small screen (or a 1024×768 test machine) gets a window that fits, centred.
        var area = SystemParameters.WorkArea;
        Width = Math.Min(Width, area.Width - 32);
        Height = Math.Min(Height, area.Height - 32);
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        NoteList.ItemsSource = notes.Select(n => n.Split('\n')[0]).ToList();
        Editor.Changed += text => { if (NoteList.SelectedIndex is >= 0 and var i) notes[i] = text; };
        NoteList.SelectedIndex = 0;
    }

    void OnSelect(object sender, SelectionChangedEventArgs e)
    {
        if (NoteList.SelectedIndex >= 0) Editor.Show(notes[NoteList.SelectedIndex]);
    }
}
