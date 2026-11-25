using System.Runtime.InteropServices;
using Microsoft.Data.Sqlite;
using NoteAnywhere.Core.Search;

namespace NoteAnywhere.Core.Tests.Search;

record TestNote(string Id, string Text, double UpdatedAt = 1, bool Locked = false, string Label = "", string Target = "")
    : ISearchableNote
{
    public IReadOnlyList<string> Tags { get; init; } = [];
}

/// The index with made-up vectors, so these run without the model.
public class SearchIndexTests
{
    // Unit vectors at a chosen angle to Query: their dot product with it is `similarity`.
    static readonly float[] Query = [1, 0];
    static float[] Similar(double similarity) => [(float)similarity, (float)Math.Sqrt(1 - similarity * similarity)];

    /// A fresh database with the Mac's tables (NoteStore.schemaV1 in Note.swift) and these notes' rows: SQLite here
    /// enforces foreign keys, as the Mac's NoteStore turns them on, so a vector needs its note.
    internal static string NewDatabase(params string[] noteIds)
    {
        Directory.CreateDirectory(AppPaths.Data);
        var connection = new SqliteConnectionStringBuilder { DataSource = Path.Combine(AppPaths.Data, $"{Guid.NewGuid():N}.sqlite") }.ToString();
        using var db = new SqliteConnection(connection);
        db.Open();
        using var create = db.CreateCommand();
        create.CommandText = """
            CREATE TABLE folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT REFERENCES folders (id) ON DELETE CASCADE);
            CREATE TABLE notes (
                id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK (kind IN ('app', 'url')), target TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '', body_md TEXT NOT NULL DEFAULT '',
                folder_id TEXT REFERENCES folders (id) ON DELETE SET NULL, pinned INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL, updated_at REAL NOT NULL, deleted_at REAL);
            CREATE TABLE embeddings (note_id TEXT PRIMARY KEY REFERENCES notes (id) ON DELETE CASCADE, model TEXT NOT NULL,
                updated_at REAL NOT NULL, vector BLOB NOT NULL);
            """;
        create.ExecuteNonQuery();
        foreach (var id in noteIds)
        {
            using var insert = db.CreateCommand();
            insert.CommandText = "INSERT INTO notes (id, kind, target, created_at, updated_at) VALUES ($id, 'url', '', 0, 0)";
            insert.Parameters.AddWithValue("$id", id);
            insert.ExecuteNonQuery();
        }
        return connection;
    }

    internal static List<(string Id, string Model, double UpdatedAt, float[] Vector)> Rows(string connection)
    {
        using var db = new SqliteConnection(connection);
        db.Open();
        using var select = db.CreateCommand();
        select.CommandText = "SELECT note_id, model, updated_at, vector FROM embeddings ORDER BY note_id";
        using var rows = select.ExecuteReader();
        List<(string, string, double, float[])> found = [];
        while (rows.Read())
            found.Add((rows.GetString(0), rows.GetString(1), rows.GetDouble(2), MemoryMarshal.Cast<byte, float>(rows.GetFieldValue<byte[]>(3)).ToArray()));
        return found;
    }

    /// Embeds from a table of texts (the query and each note's "label target\ntext"), counting what it was asked.
    sealed class FakeModel(Dictionary<string, float[]> vectors)
    {
        public List<string> Asked { get; } = [];
        public Task<float[]?> Embed(string text)
        {
            Asked.Add(text);
            return Task.FromResult(vectors.GetValueOrDefault(text));
        }
    }

    static Task<float[]?> NoModel(string text) => Task.FromResult<float[]?>(null);

    /// D77: "#note" finds #noteanywhere while you type; the exact tag (and its nested ones) still comes first.
    /// Ported from tagSearchMatchesThePartTyped (SyncStoreTests.swift); the tags are what Note.tags reads from the text.
    [Fact]
    public async Task TagSearchMatchesThePartTyped()
    {
        var partial = new TestNote("a", "Bugs\n#noteanywhere", UpdatedAt: 3) { Tags = ["noteanywhere"] };
        var exact = new TestNote("b", "Reading list #note", UpdatedAt: 1) { Tags = ["note"] };
        var nested = new TestNote("c", "#note/ideas", UpdatedAt: 2) { Tags = ["note/ideas"] };
        var other = new TestNote("d", "#flam #notnote", UpdatedAt: 4) { Tags = ["flam", "notnote"] };
        var index = new SearchIndex(NewDatabase(), NoModel);
        var hits = await index.SearchAsync("#note", [partial, exact, nested, other]);
        Assert.Equal(["c", "b", "a"], hits.Select(h => h.Note.Id));
        Assert.All(hits, h => Assert.Equal(1, h.Score));
        Assert.Equal(["a"], (await index.SearchAsync("#NOTEANY", [partial, other])).Select(h => h.Note.Id));
    }

    [Fact]
    public async Task ATagQueryIsTheWholeQuery()
    {
        var model = new FakeModel([]);
        var index = new SearchIndex(NewDatabase(), model.Embed);
        TestNote[] notes = [new("tagged", "plans for #work") { Tags = ["work"] }, new("untagged", "work on the plans")];
        Assert.Equal(["tagged"], (await index.SearchAsync(" \t#Work\u00A0 ", notes)).Select(h => h.Note.Id));  // spaces and tabs are trimmed
        Assert.Empty(model.Asked);  // and nothing is embedded
        // Anything else searches by words, as on the Mac: more words, a line break (which isn't trimmed), a bare "#".
        Assert.Equal(["tagged", "untagged"], (await index.SearchAsync("#work plans", notes)).Select(h => h.Note.Id));
        Assert.Equal(["tagged", "untagged"], (await index.SearchAsync("#work\n", notes)).Select(h => h.Note.Id));
        Assert.Empty(await index.SearchAsync("#", notes));
    }

    [Fact]
    public async Task LockedNotesAreNeverEmbeddedOrMatched()
    {
        var locked = new TestNote("locked", "secret budget plan", Locked: true) { Tags = ["budget"] };
        var open = new TestNote("open", "budget plan") { Tags = ["budget"] };
        var model = new FakeModel(new() { ["budget"] = Query, [" \nbudget plan"] = Query, [" \nsecret budget plan"] = Query });
        var connection = NewDatabase("locked", "open");
        var index = new SearchIndex(connection, model.Embed);
        await index.UpdateAsync([locked, open]);
        Assert.Equal(["open"], Rows(connection).Select(r => r.Id));
        Assert.Equal(["open"], (await index.SearchAsync("#budget", [locked, open])).Select(h => h.Note.Id));
        Assert.Equal(["open"], (await index.SearchAsync("budget", [locked, open])).Select(h => h.Note.Id));
        Assert.Equal([" \nbudget plan", "budget"], model.Asked);  // never the locked note, not even on the fly
    }

    /// Without the model (offline before its download) a note's score is half the share of the query's words it has.
    [Fact]
    public async Task WordsMatchWithoutTheModel()
    {
        var index = new SearchIndex(NewDatabase(), NoModel);
        TestNote[] notes =
        [
            new("one", "The BUDGET for next year"),
            new("both", "budget and the hiring plan"),
            new("none", "nothing here"),
            new("label", "notes", Label: "Budget Planner", Target: "com.example.planner"),  // its app's name counts too
            new("part", "budgetary"),  // a word found inside another counts, as on the Mac
        ];
        var hits = await index.SearchAsync("Budget, plan!", notes);
        Assert.Equal([("both", 0.5), ("label", 0.5), ("one", 0.25), ("part", 0.25)], hits.Select(h => (h.Note.Id, h.Score)));
        Assert.Empty(await index.SearchAsync(" ,.!? ", notes));  // no words: no results, not every note
        Assert.Equal(["cafe"], (await index.SearchAsync("e-mail", [new TestNote("cafe", "Café e-mail"), new TestNote("x", "nothing")])).Select(h => h.Note.Id));
    }

    [Fact]
    public async Task ScoreIsSimilarityPlusHalfTheWordsFound()
    {
        TestNote[] notes =
        [
            new("close", "alpha"), new("related", "beta"), new("far", "gamma"),
            new("far but named", "budget gamma"), new("unembedded", "delta"),
        ];
        var model = new FakeModel(new()
        {
            ["budget review"] = Query,
            [" \nalpha"] = Similar(0.9), [" \nbeta"] = Similar(0.3), [" \ngamma"] = Similar(0.25), [" \nbudget gamma"] = Similar(0.2),
        });
        var index = new SearchIndex(NewDatabase(), model.Embed);
        var hits = await index.SearchAsync("budget review", notes);
        // 0.25 is not above the threshold; a word found brings a note in however far its meaning.
        Assert.Equal(["close", "far but named", "related"], hits.Select(h => h.Note.Id));
        Assert.Equal([0.9, 0.45, 0.3], hits.Select(h => Math.Round(h.Score, 6)));
        Assert.Equal(["close", "far but named"], (await index.SearchAsync("budget review", notes, limit: 2)).Select(h => h.Note.Id));
    }

    [Fact]
    public async Task OnlyChangedNotesAreEmbeddedAgain()
    {
        var connection = NewDatabase("a", "b");
        var model = new FakeModel(new() { [" \nalpha"] = Similar(0.9), [" \nbeta"] = Similar(0.5), [" \nbeta, edited"] = Similar(0.6) });
        var index = new SearchIndex(connection, model.Embed);
        await index.UpdateAsync([new TestNote("a", "alpha", UpdatedAt: 10), new TestNote("b", "beta", UpdatedAt: 20)]);
        await index.UpdateAsync([new TestNote("a", "alpha", UpdatedAt: 10), new TestNote("b", "beta, edited", UpdatedAt: 21)]);
        Assert.Equal([" \nalpha", " \nbeta", " \nbeta, edited"], model.Asked);
        // Rows as the Mac writes them: the model's name, the note's updatedAt, Float32 little-endian.
        var rows = Rows(connection);
        Assert.Equal([("a", Embedder.Model, 10.0), ("b", Embedder.Model, 21.0)], rows.Select(r => (r.Id, r.Model, r.UpdatedAt)));
        Assert.Equal(Similar(0.6), rows[1].Vector);

        // Another process (the browser host) reads them and embeds just the query.
        var host = new FakeModel(new() { ["query"] = Query });
        var hits = await new SearchIndex(connection, host.Embed).SearchAsync("query", [new TestNote("a", "alpha", UpdatedAt: 10), new TestNote("b", "beta, edited", UpdatedAt: 21)]);
        Assert.Equal(["query"], host.Asked);
        Assert.Equal([("a", 0.9), ("b", 0.6)], hits.Select(h => (h.Note.Id, Math.Round(h.Score, 6))));
    }

    [Fact]
    public async Task StaleOrForeignVectorsAreNotUsed()
    {
        var connection = NewDatabase("a", "b");
        using (var db = new SqliteConnection(connection))
        {
            db.Open();
            using var insert = db.CreateCommand();
            insert.CommandText = "INSERT INTO embeddings VALUES ('a', 'some/other-model', 5, $v), ('b', $model, 5, $v)";
            insert.Parameters.AddWithValue("$v", MemoryMarshal.AsBytes(Similar(0.9).AsSpan()).ToArray());
            insert.Parameters.AddWithValue("$model", Embedder.Model);
            insert.ExecuteNonQuery();
        }
        var model = new FakeModel(new() { ["query"] = Query, [" \nalpha"] = Similar(0.4), [" \nbeta"] = Similar(0.3) });
        var index = new SearchIndex(connection, model.Embed);
        TestNote[] notes = [new("a", "alpha", UpdatedAt: 5), new("b", "beta", UpdatedAt: 6)];
        var hits = await index.SearchAsync("query", notes);
        // a's row is another model's and b's is from an older version: both are embedded on the fly, and not kept.
        Assert.Equal([("a", 0.4), ("b", 0.3)], hits.Select(h => (h.Note.Id, Math.Round(h.Score, 6))));
        Assert.Equal(["query", " \nalpha", " \nbeta"], model.Asked);
        Assert.Equal([("a", 5.0), ("b", 5.0)], Rows(connection).Select(r => (r.Id, r.UpdatedAt)));
    }

    [Fact]
    public async Task AForgottenNoteIsEmbeddedAfresh()
    {
        var model = new FakeModel(new() { ["query"] = Query, [" \nalpha"] = Similar(0.9) });
        var index = new SearchIndex(NewDatabase("a"), model.Embed);
        TestNote[] notes = [new("a", "alpha", UpdatedAt: 5)];
        await index.UpdateAsync(notes);
        index.Forget("a");
        await index.SearchAsync("query", notes);
        Assert.Equal([" \nalpha", "query", " \nalpha"], model.Asked);
    }

    [Fact]
    public async Task WithoutTheModelUpdateStopsAndKeepsNothing()
    {
        var connection = NewDatabase("a", "b");
        var model = new FakeModel([]);
        await new SearchIndex(connection, model.Embed).UpdateAsync([new TestNote("a", "alpha"), new TestNote("b", "beta")]);
        Assert.Equal([" \nalpha"], model.Asked);  // tried once, then waits for the next update
        Assert.Empty(Rows(connection));
    }
}
