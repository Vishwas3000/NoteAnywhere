using Microsoft.Data.Sqlite;

namespace NoteAnywhere.Core.Tests;

/// The schema, migrated step by step as on the Mac, so a store made on either is laid out the same; each test has its own file.
public class MigrationTests
{
    /// sqlite_master of a store the Mac's NoteStore made in an empty folder (macOS 26, after migrations v1–v7).
    const string MacSchema = """
        index notes_dirty notes | CREATE INDEX notes_dirty ON notes (dirty) WHERE dirty = 1
        index notes_kind_target notes | CREATE INDEX notes_kind_target ON notes (kind, target)
        index sqlite_autoindex_attachments_1 attachments | -
        index sqlite_autoindex_embeddings_1 embeddings | -
        index sqlite_autoindex_folders_1 folders | -
        index sqlite_autoindex_icons_1 icons | -
        index sqlite_autoindex_images_1 images | -
        index sqlite_autoindex_links_1 links | -
        index sqlite_autoindex_notes_1 notes | -
        index sqlite_autoindex_snapshots_1 snapshots | -
        index sqlite_autoindex_suggestions_1 suggestions | -
        index sqlite_autoindex_sync_state_1 sync_state | -
        index sqlite_autoindex_tags_1 tags | -
        table attachments attachments | CREATE TABLE attachments (id TEXT PRIMARY KEY, note_id TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE,
            kind TEXT NOT NULL, path TEXT NOT NULL, meta_json TEXT)
        table embeddings embeddings | CREATE TABLE embeddings (note_id TEXT PRIMARY KEY REFERENCES notes (id) ON DELETE CASCADE, model TEXT NOT NULL,
            updated_at REAL NOT NULL, vector BLOB NOT NULL)
        table folders folders | CREATE TABLE folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT REFERENCES folders (id) ON DELETE CASCADE, updated_at REAL NOT NULL DEFAULT 0, deleted_at REAL, dirty INTEGER NOT NULL DEFAULT 1)
        table icons icons | CREATE TABLE icons (key TEXT PRIMARY KEY, png BLOB NOT NULL, fetched_at REAL NOT NULL)
        table images images | CREATE TABLE images (id TEXT PRIMARY KEY, type TEXT NOT NULL, created_at REAL NOT NULL,
            dirty INTEGER NOT NULL DEFAULT 1)
        table links links | CREATE TABLE links (from_note TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE,
            to_note TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE, PRIMARY KEY (from_note, to_note))
        table notes notes | CREATE TABLE notes (
            id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK (kind IN ('app', 'url')), target TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '', body_md TEXT NOT NULL DEFAULT '',
            folder_id TEXT REFERENCES folders (id) ON DELETE SET NULL, pinned INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL, updated_at REAL NOT NULL, deleted_at REAL, dirty INTEGER NOT NULL DEFAULT 1, color TEXT, locked INTEGER NOT NULL DEFAULT 0, starred INTEGER NOT NULL DEFAULT 0)
        table snapshots snapshots | CREATE TABLE snapshots (note_id TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE, day TEXT NOT NULL,
            body_md TEXT NOT NULL, updated_at REAL NOT NULL, dirty INTEGER NOT NULL DEFAULT 1, PRIMARY KEY (note_id, day))
        table suggestions suggestions | CREATE TABLE suggestions (note_id TEXT PRIMARY KEY REFERENCES notes (id) ON DELETE CASCADE,
            updated_at REAL NOT NULL, title TEXT NOT NULL, tags_json TEXT NOT NULL)
        table sync_state sync_state | CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)
        table tags tags | CREATE TABLE tags (note_id TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE, tag TEXT NOT NULL, PRIMARY KEY (note_id, tag))
        """;

    const string Schema = "SELECT type || ' ' || name || ' ' || tbl_name || ' | ' || ifnull(sql, '-') FROM sqlite_master ORDER BY type, name";

    static string NewStore() => Path.Combine(Scratch.Dir, "migrations", Guid.NewGuid().ToString("N"), "memorynotes.sqlite");

    static void Exec(SqliteConnection db, string sql)
    {
        using var command = db.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    static List<string> Rows(SqliteConnection db, string sql)
    {
        using var command = db.CreateCommand();
        command.CommandText = sql;
        using var reader = command.ExecuteReader();
        List<string> rows = [];
        while (reader.Read()) rows.Add(reader.IsDBNull(0) ? "NULL" : reader.GetString(0));
        return rows;
    }

    [Fact]
    public void ANewStoreIsLaidOutLikeTheMacs()
    {
        using var db = NoteStore.Open(NewStore());
        Assert.Equal(["7"], Rows(db, "PRAGMA user_version"));
        Assert.Equal(["wal"], Rows(db, "PRAGMA journal_mode"));
        Assert.Equal(["1"], Rows(db, "PRAGMA foreign_keys"));
        Assert.Equal(MacSchema, string.Join("\n", Rows(db, Schema)));
        NoteStore.Migrate(db);  // again, as each process does on opening it: nothing to do
        Assert.Equal(MacSchema, string.Join("\n", Rows(db, Schema)));
    }

    [Fact]
    public void AStoreFromBeforeSyncKeepsItsNotes()
    {
        var path = NewStore();
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using (var old = new SqliteConnection($"Data Source={path};Pooling=False"))
        {
            old.Open();
            Exec(old, NoteStore.SchemaV1);
            Exec(old, """
                INSERT INTO folders (id, name) VALUES ('f', 'Work');
                INSERT INTO notes (id, kind, target, title, body_md, folder_id, pinned, created_at, updated_at) VALUES ('a', 'url', 'x.com', 'X', 'kept', 'f', 1, 1, 2);
                INSERT INTO snapshots (note_id, day, body_md, updated_at) VALUES ('a', '2026-11-01', 'kept', 2);
                PRAGMA user_version = 1;
                """);
        }
        using var db = NoteStore.Open(path);
        Assert.Equal(["7"], Rows(db, "PRAGMA user_version"));
        // The later columns arrive with their defaults: everything is dirty, so the first sync pushes it all.
        Assert.Equal(["a kept 1 f 1 - 0 0"], Rows(db, "SELECT id || ' ' || body_md || ' ' || pinned || ' ' || folder_id || ' ' || dirty || ' ' || ifnull(color, '-') || ' ' || locked || ' ' || starred FROM notes"));
        Assert.Equal(["f Work 1 - 1"], Rows(db, "SELECT id || ' ' || name || ' ' || (updated_at = 0) || ' ' || ifnull(deleted_at, '-') || ' ' || dirty FROM folders"));
        Assert.Equal(["a 2026-11-01 1"], Rows(db, "SELECT note_id || ' ' || day || ' ' || dirty FROM snapshots"));
        Assert.Equal(MacSchema, string.Join("\n", Rows(db, Schema)));
    }

    /// D76: each uppercase/lowercase pair becomes one note (the newer edit wins), keeping every snapshot day and tag; folders merge too.
    [Fact]
    public void Version7MergesCaseDuplicates()
    {
        using var db = NoteStore.Open(NewStore());  // an empty store at the current version
        const string a = "AAAAAAAA-1111-4111-8111-111111111111", b = "BBBBBBBB-2222-4222-8222-222222222222";
        const string c = "CCCCCCCC-3333-4333-8333-333333333333", f = "FFFFFFFF-4444-4444-8444-444444444444";
        string la = a.ToLowerInvariant(), lb = b.ToLowerInvariant(), lc = c.ToLowerInvariant(), lf = f.ToLowerInvariant();
        // a: edited here after a sync pulled its twin (uppercase newer); b: the pulled copy is newer; c: never synced, no twin.
        Exec(db, $"""
            INSERT INTO folders (id, name, updated_at, dirty) VALUES ('{f}', 'Work', 1, 0), ('{lf}', 'Work', 1, 0);
            INSERT INTO notes (id, kind, target, body_md, folder_id, created_at, updated_at, dirty) VALUES
                ('{a}', 'url', 'x.com', 'a new', '{f}', 1, 20, 1), ('{la}', 'url', 'x.com', 'a old', '{lf}', 1, 10, 0),
                ('{b}', 'url', 'x.com', 'b old', NULL, 1, 10, 0), ('{lb}', 'url', 'x.com', 'b new', NULL, 1, 20, 0),
                ('{c}', 'url', 'x.com', 'c', '{f}', 1, 10, 1);
            INSERT INTO snapshots (note_id, day, body_md, updated_at, dirty) VALUES
                ('{a}', '2026-11-01', 'only here', 5, 0), ('{a}', '2026-11-02', 'a new', 20, 1),
                ('{la}', '2026-11-02', 'a old', 10, 0), ('{c}', '2026-11-01', 'c', 10, 1);
            INSERT INTO tags (note_id, tag) VALUES ('{a}', 'work'), ('{la}', 'work');
            PRAGMA user_version = 6;
            """);
        NoteStore.Migrate(db);
        Assert.Equal([$"{la} a new 1 {lf}", $"{lb} b new 0 -", $"{lc} c 1 {lf}"],
            Rows(db, "SELECT id || ' ' || body_md || ' ' || dirty || ' ' || ifnull(folder_id, '-') FROM notes ORDER BY id"));
        Assert.Equal([$"{la} 2026-11-01 only here", $"{la} 2026-11-02 a new", $"{lc} 2026-11-01 c"],
            Rows(db, "SELECT note_id || ' ' || day || ' ' || body_md FROM snapshots ORDER BY note_id, day"));
        Assert.Equal([la], Rows(db, "SELECT note_id FROM tags"));
        Assert.Equal([lf], Rows(db, "SELECT id FROM folders"));
        Assert.Empty(Rows(db, "PRAGMA foreign_key_check"));
        Assert.Equal(["7"], Rows(db, "PRAGMA user_version"));
    }
}
