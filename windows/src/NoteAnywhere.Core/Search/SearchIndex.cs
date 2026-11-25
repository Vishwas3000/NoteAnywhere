using System.Collections.Concurrent;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace NoteAnywhere.Core.Search;

/// What search reads of a note; the store's note type implements it.
public interface ISearchableNote
{
    string Id { get; }
    /// The app's or site's name; with Target (its bundle id or "host/path") it's matched and embedded with the text, as
    /// on the Mac.
    string Label { get; }
    string Target { get; }
    string Text { get; }
    double UpdatedAt { get; }
    bool Locked { get; }
    /// Its #tags, lowercased (Note.tags on the Mac).
    IReadOnlyList<string> Tags { get; }
}

/// A note that matched, with the caller's own note type. Score: cosine similarity plus half the share of the query's
/// words found in the note, or 1 for every note a #tag query lists.
public sealed record Hit<TNote>(TNote Note, double Score);

/// Hybrid search, as the Mac's SearchIndex.swift: MiniLM similarity plus a boost for notes containing the query's words.
/// Vectors are kept in the embeddings table of `connectionString`'s database, which the store has created; the app
/// writes them (UpdateAsync) and other processes only read them, so they embed just the query.
/// `embed` is Embedder.EmbedAsync: null when there's no model, and search then matches words only.
public sealed partial class SearchIndex(string connectionString, Func<string, Task<float[]?>> embed)
{
    readonly ConcurrentDictionary<string, (double UpdatedAt, float[] Vector)> cache = Load(connectionString);

    /// Embeds new or changed notes (a different updatedAt from the stored vector's), never locked ones.
    public async Task UpdateAsync(IEnumerable<ISearchableNote> notes)
    {
        foreach (var note in notes)
        {
            if (note.Locked || (cache.TryGetValue(note.Id, out var stored) && stored.UpdatedAt == note.UpdatedAt)) continue;
            if (await embed(Document(note)).ConfigureAwait(false) is not { } vector) break;
            cache[note.Id] = (note.UpdatedAt, vector);
            try { Save(note.Id, note.UpdatedAt, vector); }
            catch (SqliteException e) { Console.Error.WriteLine($"NoteAnywhere: couldn't keep the search vector of {note.Id}: {e.Message}"); }
        }
    }

    /// A note that was just locked: its vector, made from readable text, isn't used again. The store deletes its row as
    /// it locks the note, as NoteStore.setLocked does on the Mac.
    public void Forget(string id) => cache.TryRemove(id, out _);

    /// "#ml" lists the notes with that tag (or one nested under it), then those with a tag that starts with it, so "#note"
    /// finds #noteanywhere while you type (D77); newest first in each, all of them. Any other query ranks notes by meaning
    /// and by words, best first. Locked notes never match.
    public async Task<List<Hit<TNote>>> SearchAsync<TNote>(string query, IEnumerable<TNote> notes, int limit = 20)
        where TNote : ISearchableNote
    {
        var readable = notes.Where(n => !n.Locked).ToList();
        if (TagQuery().Match(query) is { Success: true } match)
        {
            var tag = match.Groups[1].Value.ToLowerInvariant();
            return [.. readable.Where(n => n.Tags.Any(t => t.StartsWith(tag, StringComparison.Ordinal)))
                .OrderByDescending(n => n.Tags.Any(t => t == tag || t.StartsWith(tag + "/", StringComparison.Ordinal)))
                .ThenByDescending(n => n.UpdatedAt)
                .Select(n => new Hit<TNote>(n, 1))];
        }
        var words = Words(query.ToLowerInvariant());
        if (words.Count == 0) return [];
        var queryVector = await embed(query).ConfigureAwait(false);
        List<Hit<TNote>> hits = [];
        foreach (var note in readable)
        {
            var haystack = Document(note).ToLowerInvariant();
            var keyword = (double)words.Count(w => haystack.Contains(w, StringComparison.Ordinal)) / words.Count;
            var similarity = 0.0;
            if (queryVector is not null)
            {
                var vector = cache.TryGetValue(note.Id, out var stored) && stored.UpdatedAt == note.UpdatedAt ? stored.Vector : null;
                vector ??= await embed(Document(note)).ConfigureAwait(false);  // not indexed yet: embed on the fly
                if (vector is not null) similarity = Dot(queryVector, vector);
            }
            // Vectors are normalised, so the dot product is cosine similarity; unrelated MiniLM pairs sit below ~0.25.
            if (similarity > 0.25 || keyword > 0) hits.Add(new(note, similarity + 0.5 * keyword));
        }
        return [.. hits.OrderByDescending(h => h.Score).Take(limit)];
    }

    static string Document(ISearchableNote note) => $"{note.Label} {note.Target}\n{note.Text}";

    /// Swift's split { !$0.isLetter && !$0.isNumber }: by whole characters, so an accent or a vowel sign stays in its word.
    internal static List<string> Words(string text)
    {
        List<string> words = [];
        var word = new StringBuilder();
        var characters = StringInfo.GetTextElementEnumerator(text);
        while (characters.MoveNext())
        {
            var character = characters.GetTextElement();
            Rune.DecodeFromUtf16(character, out var first, out _);
            if (Rune.IsLetter(first) || Rune.IsNumber(first)) word.Append(character);
            else if (word.Length > 0) { words.Add(word.ToString()); word.Clear(); }
        }
        if (word.Length > 0) words.Add(word.ToString());
        return words;
    }

    static double Dot(float[] a, float[] b)
    {
        var sum = 0f;  // in Float, as the Mac sums
        for (var i = 0; i < Math.Min(a.Length, b.Length); i++) sum += a[i] * b[i];
        return sum;
    }

    // Unlike the Mac's NoteStore.vectors(), no JOIN to skip deleted notes: only the notes a caller passes are looked up.
    static ConcurrentDictionary<string, (double, float[])> Load(string connectionString)
    {
        var vectors = new ConcurrentDictionary<string, (double, float[])>();
        try
        {
            using var db = new SqliteConnection(connectionString);
            db.Open();
            using var select = db.CreateCommand();
            select.CommandText = "SELECT note_id, updated_at, vector FROM embeddings WHERE model = $model";
            select.Parameters.AddWithValue("$model", Embedder.Model);
            using var rows = select.ExecuteReader();
            while (rows.Read()) vectors[rows.GetString(0)] = (rows.GetDouble(1), MemoryMarshal.Cast<byte, float>(rows.GetFieldValue<byte[]>(2)).ToArray());
        }
        catch (SqliteException e)  // as on the Mac: search still works, embedding notes as it goes
        {
            Console.Error.WriteLine($"NoteAnywhere: couldn't read the search vectors: {e.Message}");
        }
        return vectors;
    }

    void Save(string id, double updatedAt, float[] vector)
    {
        using var db = new SqliteConnection(connectionString);
        db.Open();
        using var upsert = db.CreateCommand();
        upsert.CommandText = """
            INSERT INTO embeddings (note_id, model, updated_at, vector) VALUES ($id, $model, $updatedAt, $vector)
            ON CONFLICT (note_id) DO UPDATE SET model = excluded.model, updated_at = excluded.updated_at, vector = excluded.vector
            """;
        upsert.Parameters.AddWithValue("$id", id);
        upsert.Parameters.AddWithValue("$model", Embedder.Model);
        upsert.Parameters.AddWithValue("$updatedAt", updatedAt);
        upsert.Parameters.AddWithValue("$vector", MemoryMarshal.AsBytes(vector.AsSpan()).ToArray());  // Float32, little-endian, as the Mac writes it
        upsert.ExecuteNonQuery();
    }

    /// The Mac trims spaces and tabs (not line breaks), then wants all of it to be "#" and a word without "#".
    [GeneratedRegex(@"^[\t\p{Zs}]*#([^\s#]+)[\t\p{Zs}]*\z")]
    private static partial Regex TagQuery();
}
