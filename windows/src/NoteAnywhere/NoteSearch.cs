using System.Diagnostics;
using System.IO;
using System.Windows.Threading;
using NoteAnywhere.Core;
using NoteAnywhere.Core.Search;

namespace NoteAnywhere;

/// Search by meaning and by words (SearchIndex, the Mac's ranking). As on the Mac, the 90 MB model comes with the first
/// search (the privacy page says so); after that the index follows edits, two seconds after they stop.
static class NoteSearch
{
    static readonly Embedder Embedder = new();
    static readonly SearchIndex Index = new($"Data Source={Path.Combine(AppPaths.Data, "memorynotes.sqlite")}", Embedder.EmbedAsync);
    static readonly DispatcherTimer Settle = new() { Interval = TimeSpan.FromSeconds(2) };

    static bool ModelOnDisk => Embedder.HasModel;

    public static void Start()
    {
        Settle.Tick += (_, _) => { Settle.Stop(); _ = Update(); };
        NotesModel.Shared.Changed += () => { Settle.Stop(); Settle.Start(); };
        if (ModelOnDisk) _ = Update();
    }

    /// The notes for a query, best first; words only until the model is on this PC.
    public static async Task<List<Note>> Search(string query)
    {
        var hits = await Index.SearchAsync(query, NotesModel.Shared.Notes);
        if (ModelOnDisk) Settle.Start();  // the first search brought the model: index every note now
        return hits.Select(h => h.Note).ToList();
    }

    static async Task Update()
    {
        if (!ModelOnDisk) return;
        try { await Index.UpdateAsync(NotesModel.Shared.Notes); }
        catch (Exception e) { Trace.WriteLine($"NoteAnywhere: couldn't update the search index: {e.Message}"); }
    }
}
