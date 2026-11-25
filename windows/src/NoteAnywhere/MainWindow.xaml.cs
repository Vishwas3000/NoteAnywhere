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
        NoteList.ItemsSource = notes.Select(n => n.Split('\n')[0]).ToList();
        Editor.Changed += text => { if (NoteList.SelectedIndex is >= 0 and var i) notes[i] = text; };
        NoteList.SelectedIndex = 0;
    }

    void OnSelect(object sender, SelectionChangedEventArgs e)
    {
        if (NoteList.SelectedIndex >= 0) Editor.Show(notes[NoteList.SelectedIndex]);
    }
}
