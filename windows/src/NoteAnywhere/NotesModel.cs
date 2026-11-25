using System.Diagnostics;
using System.Windows;
using NoteAnywhere.Core;

namespace NoteAnywhere;

/// The notes and folders every window shows, as the Mac's NotesModel. Reloaded when the store changes, here or in
/// another process (the browser host, the MCP server, sync); Changed fires only when something visible did change, so
/// typing (saved on every keystroke) doesn't rebuild the sidebar twice.
sealed class NotesModel
{
    public static NotesModel Shared { get; } = new();

    readonly NoteStoreWatcher watcher = new();
    string signature = "";

    public List<Note> Notes { get; private set; } = [];
    public List<Folder> Folders { get; private set; } = [];
    public event Action? Changed;

    NotesModel()
    {
        Reload();
        watcher.Changed += () => Application.Current?.Dispatcher.BeginInvoke(Reload);
    }

    public Note? Find(string id) => Notes.FirstOrDefault(n => n.Id == id);

    public void Reload()
    {
        try
        {
            Notes = NoteStore.LoadAll();
            Folders = NoteStore.Folders();
        }
        catch (Exception e) { Trace.WriteLine($"NoteAnywhere: couldn't read the notes: {e.Message}"); }
        var now = string.Join("|", Notes.Select(n => $"{n.Id}:{n.UpdatedAt}:{n.Pinned}:{n.Starred}:{n.FolderID}:{n.Color}:{n.Locked}:{n.Target}"))
                  + "||" + string.Join("|", Folders.Select(f => $"{f.Id}:{f.Name}"));
        if (now == signature) return;
        signature = now;
        Changed?.Invoke();
    }

    public Note Add(NoteKind kind, string target, string label, string? folderID = null, string text = "", bool starred = false)
    {
        var now = NoteActions.Now;
        var note = new Note { Kind = kind, Target = target, Label = label, Text = text, CreatedAt = now, UpdatedAt = now };
        NoteStore.Save(note);
        if (folderID != null || starred) NoteStore.SaveMeta(note = note with { FolderID = folderID, Starred = starred });
        Reload();
        return note;
    }

    /// The editor's every keystroke; the row's title and preview follow at once.
    public void SaveText(string id, string text)
    {
        if (Find(id) is not { } note || note.Text == text) return;
        var saved = note with { Text = text, UpdatedAt = NoteActions.Now };
        NoteStore.Save(saved);
        Notes = Notes.Select(n => n.Id == id ? saved : n).ToList();  // the watcher's next poll refreshes the rows
    }

    public void Update(string id, Func<Note, Note> change)
    {
        if (Find(id) is not { } note) return;
        NoteStore.SaveMeta(change(note));
        Reload();
    }

    public void SetTarget(string id, string target, string label)
    {
        if (Find(id) is not { } note) return;
        NoteStore.Save(note with { Target = target, Label = label, UpdatedAt = NoteActions.Now });
        Reload();
    }

    public void Delete(string id)
    {
        NoteStore.Delete(id);
        Reload();
    }

    public Note Duplicate(Note note)
    {
        var copy = Add(note.Kind, note.Target, note.Label, note.FolderID, note.Text);
        if (note.Color != null) Update(copy.Id, n => n with { Color = note.Color });
        return copy;
    }

    public Folder AddFolder(string name)
    {
        var folder = new Folder { Name = name, UpdatedAt = NoteActions.Now };
        NoteStore.SaveFolder(folder);
        Reload();
        return folder;
    }

    public void RenameFolder(Folder folder, string name)
    {
        NoteStore.SaveFolder(folder with { Name = name, UpdatedAt = NoteActions.Now });
        Reload();
    }

    public void DeleteFolder(string id)
    {
        NoteStore.DeleteFolder(id);
        Reload();
    }
}
