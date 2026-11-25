using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.Data.Sqlite;

namespace NoteAnywhere.Core;

/// One SQLite database for the app and the browser host, a port of NoteStore in Note.swift; deletes are soft, so sync can carry them.
public static class NoteStore
{
    public sealed class BadID() : Exception("Not a note id.");
    public sealed class ImageError(string message) : Exception(message);

    public const string EmbeddingModel = "sentence-transformers/all-MiniLM-L6-v2";

    internal static string DatabasePath => Path.Combine(AppPaths.Data, "memorynotes.sqlite");

    // Notes

    public static List<Note> LoadAll() => TryQuery("""
        SELECT id, kind, target, title, body_md, created_at, updated_at, pinned, folder_id, color, locked, starred FROM notes
        WHERE deleted_at IS NULL ORDER BY created_at
        """, [], ReadNote);

    /// Website notes for a page and every page under it, never its parents: "github.com/" is the whole site.
    public static List<Note> NotesUnder(string url)
    {
        var page = url.TrimEnd('/');
        // "0" sorts right after "/", so [page/, page0) is exactly the targets under this page, on the (kind, target) index.
        return TryQuery("""
            SELECT id, kind, target, title, body_md, created_at, updated_at, pinned, folder_id, color, locked, starred FROM notes
            WHERE deleted_at IS NULL AND locked = 0 AND kind = 'url' AND (target = ?1 OR (target >= ?2 AND target < ?3))
            ORDER BY created_at
            """, [page, page + "/", page + "0"], ReadNote);
    }

    public static List<Snapshot> LoadHistory() => TryQuery("""
        SELECT n.id, n.kind, n.target, n.title, s.body_md, n.created_at, s.updated_at,
            n.pinned, n.folder_id, n.color, n.locked, n.starred, s.day
        FROM snapshots s JOIN notes n ON n.id = s.note_id
        WHERE n.deleted_at IS NULL ORDER BY s.updated_at
        """, [], row => new Snapshot(Text(row, 12), ReadNote(row)));

    /// Upserts the note and that day's snapshot together; a deleted note, or one whose kind differs (the browser reusing an app note's id), stays.
    public static void Save(Note note)
    {
        Validate(note.Id);
        Transaction(() =>
        {
            var changed = Run("""
                INSERT INTO notes (id, kind, target, title, body_md, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                ON CONFLICT (id) DO UPDATE SET target = excluded.target, title = excluded.title,
                    body_md = excluded.body_md, updated_at = excluded.updated_at, dirty = 1
                WHERE notes.deleted_at IS NULL AND notes.kind = excluded.kind
                    AND (notes.locked = 0 OR excluded.body_md LIKE 'mnlock:v1:%')  -- a stale tab can't unlock it
                """, [note.Id, note.Kind.RawValue, note.Target, note.Label, note.Text, note.CreatedAt, note.UpdatedAt]);
            if (changed == 0) return;
            Run("""
                INSERT INTO snapshots (note_id, day, body_md, updated_at) VALUES (?1, ?2, ?3, ?4)
                ON CONFLICT (note_id, day) DO UPDATE SET body_md = excluded.body_md, updated_at = excluded.updated_at, dirty = 1
                """, [note.Id, Day(note.UpdatedAt), note.Text, note.UpdatedAt]);
        });
    }

    public static void Delete(string id)
    {
        Validate(id);
        var now = Note.Now();
        Transaction(() => Run("UPDATE notes SET deleted_at = ?1, updated_at = ?2, dirty = 1 WHERE id = ?3 AND deleted_at IS NULL", [now, now, id]));
    }

    // Images (D53): bytes in images/<id>, shown in notes as ![](noteimage:<id>)

    /// What browsers and WebKit both draw; HEIC only in WebKit (Mac, iPhone), kept here so sync carries it.
    public static readonly IReadOnlySet<string> ImageTypes = new HashSet<string>
        { "image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "image/heic", "image/heif" };
    public const int MaxImageBytes = 20 << 20;
    public const string ImageScheme = "noteimage";  // served by the apps' web views
    public static string ImagesDir => Path.Combine(AppPaths.Data, "images");

    /// Keeps a pasted or dropped image and returns its id; the note that shows it saves separately, which tells sync to push both.
    // shortcut: images are never deleted (like a deleted note's text); clean up unreferenced ones with "wipe on delete".
    public static string SaveImage(byte[] data, string type)
    {
        if (!ImageTypes.Contains(type)) throw new ImageError($"Notes can't hold this kind of image ({type}).");
        if (data.Length > MaxImageBytes) throw new ImageError($"Images can be up to {MaxImageBytes >> 20} MB.");
        var id = Note.NewID();
        WriteAtomically(Path.Combine(ImagesDir, id), data);
        Transaction(() => Run("INSERT INTO images (id, type, created_at) VALUES (?1, ?2, ?3)", [id, type, Note.Now()]));
        return id;
    }

    /// Null when the id is unknown, or its bytes haven't arrived from another device yet.
    public static (byte[] Data, string Type)? Image(string id)
    {
        if (!IsID(id) || TryQuery("SELECT type FROM images WHERE id = ?1", [id], row => Text(row, 0)) is not [var type, ..]) return null;
        try { return (File.ReadAllBytes(Path.Combine(ImagesDir, id)), type); }
        catch (Exception e) when (IsStorageError(e)) { return null; }
    }

    // Locked notes

    /// Locks or unlocks a note; locking also replaces its history with the envelope and drops its search vector: no readable copy is left.
    public static void SetLocked(string id, string text, bool locked)
    {
        Validate(id);
        var now = Note.Now();
        Transaction(() =>
        {
            Run("UPDATE notes SET body_md = ?1, locked = ?2, updated_at = ?3, dirty = 1 WHERE id = ?4 AND deleted_at IS NULL",
                [text, locked ? 1 : 0, now, id]);
            Run("UPDATE snapshots SET body_md = ?1, updated_at = ?2, dirty = 1 WHERE note_id = ?3", [text, now, id]);
            Run("DELETE FROM embeddings WHERE note_id = ?1", [id]);
        });
    }

    // Pins, colours, folders

    /// Pin, star, colour or folder: a millisecond onto updated_at, enough for sync's newer-wins rule without moving the note to "Today".
    public static void SaveMeta(Note note)
    {
        Validate(note.Id);
        Transaction(() => Run("""
            UPDATE notes SET pinned = ?1, starred = ?2, folder_id = (SELECT id FROM folders WHERE id = ?3 AND deleted_at IS NULL),
                color = ?4, updated_at = updated_at + 1, dirty = 1
            WHERE id = ?5 AND deleted_at IS NULL
            """, [note.Pinned ? 1 : 0, note.Starred ? 1 : 0, note.FolderID, note.Color?.RawValue, note.Id]));
    }

    public static List<Folder> Folders() => TryQuery("SELECT id, name, updated_at FROM folders WHERE deleted_at IS NULL ORDER BY name COLLATE NOCASE", [],
        row => new Folder { Id = Text(row, 0), Name = Text(row, 1), UpdatedAt = row.GetDouble(2) });

    public static void SaveFolder(Folder folder)
    {
        Validate(folder.Id);
        Transaction(() => Run("""
            INSERT INTO folders (id, name, updated_at, dirty) VALUES (?1, ?2, ?3, 1)
            ON CONFLICT (id) DO UPDATE SET name = excluded.name, updated_at = excluded.updated_at, dirty = 1
            """, [folder.Id, folder.Name, Note.Now()]));
    }

    /// A tombstone; its notes return to All Notes (they aren't deleted with it).
    public static void DeleteFolder(string id)
    {
        Validate(id);
        var now = Note.Now();
        Transaction(() =>
        {
            Run("UPDATE folders SET deleted_at = ?1, updated_at = ?2, dirty = 1 WHERE id = ?3", [now, now, id]);
            Run("UPDATE notes SET folder_id = NULL, updated_at = updated_at + 1, dirty = 1 WHERE folder_id = ?1", [id]);
        });
    }

    // Cloud sync: rows as the server stores them (see CloudSync); JsonNamingPolicy.SnakeCaseLower gives its column names.

    public sealed record CloudNote(string Id, string Kind, string Target, string Label, string BodyMd, double CreatedAt, double UpdatedAt,
        double? DeletedAt = null, bool? Pinned = null, string? FolderID = null, string? Color = null, bool? Locked = null, bool? Starred = null,
        long? Seq = null);

    public sealed record CloudFolder(string Id, string Name, double UpdatedAt, double? DeletedAt = null, long? Seq = null);

    public sealed record CloudSnapshot(string NoteID, string Day, string BodyMd, double UpdatedAt, long? Seq = null);

    /// An image row: the bytes travel separately, sealed, through Storage (CloudSync).
    public sealed record CloudImage(string Id, string Type, double CreatedAt, long? Seq = null);

    public static List<CloudFolder> DirtyFolders() => TryQuery("SELECT id, name, updated_at, deleted_at FROM folders WHERE dirty = 1", [],
        row => new CloudFolder(Text(row, 0), Text(row, 1), row.GetDouble(2), row.IsDBNull(3) ? null : row.GetDouble(3)));

    public static List<CloudNote> DirtyNotes(int limit = 200) => TryQuery("""
        SELECT id, kind, target, title, body_md, created_at, updated_at, deleted_at, pinned, folder_id, color, locked, starred
        FROM notes WHERE dirty = 1 LIMIT ?1
        """, [limit], row => new CloudNote(Text(row, 0), Text(row, 1), Text(row, 2), Text(row, 3), Text(row, 4),
            row.GetDouble(5), row.GetDouble(6), row.IsDBNull(7) ? null : row.GetDouble(7),
            Pinned: row.GetInt64(8) != 0, FolderID: row.IsDBNull(9) ? null : Text(row, 9), Color: row.IsDBNull(10) ? null : Text(row, 10),
            Locked: row.GetInt64(11) != 0, Starred: row.GetInt64(12) != 0));

    public static List<CloudSnapshot> DirtySnapshots(int limit = 500) => TryQuery("SELECT note_id, day, body_md, updated_at FROM snapshots WHERE dirty = 1 LIMIT ?1",
        [limit], row => new CloudSnapshot(Text(row, 0), Text(row, 1), Text(row, 2), row.GetDouble(3)));

    public static List<CloudImage> DirtyImages(int limit = 50) => TryQuery("SELECT id, type, created_at FROM images WHERE dirty = 1 LIMIT ?1",
        [limit], row => new CloudImage(Text(row, 0), Text(row, 1), row.GetDouble(2)));

    /// A pulled image row worth downloading: well-formed, and not complete on this device yet. Bad rows are skipped, like bad notes.
    public static bool WantsImage(CloudImage image)
    {
        if (!IsID(image.Id) || !ImageTypes.Contains(image.Type)) return false;
        var hasRow = TryQuery("SELECT 1 FROM images WHERE id = ?1", [image.Id], _ => true).Count > 0;
        return !hasRow || !File.Exists(Path.Combine(ImagesDir, image.Id));
    }

    /// A pulled image's bytes: the file first, then the row, so a row never points at nothing.
    public static void SaveRemoteImage(CloudImage image, byte[] data)
    {
        Validate(image.Id);
        if (!ImageTypes.Contains(image.Type) || data.Length > MaxImageBytes)
            throw new ImageError($"A synced image isn't one notes can hold ({image.Type}, {data.Length} bytes).");
        WriteAtomically(Path.Combine(ImagesDir, image.Id), data);
        Transaction(() => Run("INSERT OR IGNORE INTO images (id, type, created_at, dirty) VALUES (?1, ?2, ?3, 0)", [image.Id, image.Type, image.CreatedAt]));
    }

    /// After a push: clean only rows nobody edited meanwhile. Images never change, so any pushed one is clean.
    public static void MarkPushed(IReadOnlyList<CloudNote>? notes = null, IReadOnlyList<CloudSnapshot>? snapshots = null,
        IReadOnlyList<CloudFolder>? folders = null, IReadOnlyList<CloudImage>? images = null)
    {
        Transaction(() =>
        {
            foreach (var i in images ?? []) Run("UPDATE images SET dirty = 0 WHERE id = ?1", [i.Id]);
            foreach (var f in folders ?? []) Run("UPDATE folders SET dirty = 0 WHERE id = ?1 AND updated_at = ?2", [f.Id, f.UpdatedAt]);
            foreach (var n in notes ?? []) Run("UPDATE notes SET dirty = 0 WHERE id = ?1 AND updated_at = ?2", [n.Id, n.UpdatedAt]);
            foreach (var s in snapshots ?? [])
                Run("UPDATE snapshots SET dirty = 0 WHERE note_id = ?1 AND day = ?2 AND updated_at = ?3", [s.NoteID, s.Day, s.UpdatedAt]);
        });
    }

    /// Pulled rows: the newer edit wins and deletes stick, as on the server.
    public static void ApplyRemote(IReadOnlyList<CloudNote> notes, IReadOnlyList<CloudSnapshot> snapshots, IReadOnlyList<CloudFolder>? folders = null)
    {
        Transaction(() =>
        {
            foreach (var f in (folders ?? []).Where(f => IsID(f.Id)))  // before notes, which may point at them
            {
                Run("""
                    INSERT INTO folders (id, name, updated_at, deleted_at, dirty) VALUES (?1, ?2, ?3, ?4, 0)
                    ON CONFLICT (id) DO UPDATE SET name = excluded.name, updated_at = excluded.updated_at,
                        deleted_at = coalesce(folders.deleted_at, excluded.deleted_at), dirty = 0
                    WHERE excluded.updated_at > folders.updated_at
                    """, [f.Id, f.Name, f.UpdatedAt, f.DeletedAt]);
            }
            foreach (var n in notes.Where(n => IsID(n.Id) && n.Kind is "app" or "url"))
            {
                Run("""
                    INSERT INTO notes (id, kind, target, title, body_md, created_at, updated_at, deleted_at,
                        pinned, folder_id, color, locked, starred, dirty)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, (SELECT id FROM folders WHERE id = ?10), ?11, ?12, ?13, 0)
                    ON CONFLICT (id) DO UPDATE SET target = excluded.target, title = excluded.title, body_md = excluded.body_md,
                        updated_at = excluded.updated_at, deleted_at = coalesce(notes.deleted_at, excluded.deleted_at),
                        pinned = excluded.pinned, folder_id = excluded.folder_id, color = excluded.color,
                        locked = excluded.locked, starred = excluded.starred, dirty = 0
                    WHERE excluded.updated_at > notes.updated_at
                    """, [n.Id, n.Kind, n.Target, n.Label, n.BodyMd, n.CreatedAt, n.UpdatedAt, n.DeletedAt,
                        n.Pinned == true ? 1 : 0, n.FolderID, n.Color, n.Locked == true ? 1 : 0, n.Starred == true ? 1 : 0]);
                if (n.DeletedAt is { } at)  // deleted elsewhere, even if edited here later
                    Run("UPDATE notes SET deleted_at = ?1 WHERE id = ?2 AND deleted_at IS NULL", [at, n.Id]);
            }
            foreach (var s in snapshots)
            {
                Run("""
                    INSERT INTO snapshots (note_id, day, body_md, updated_at, dirty)
                    SELECT ?1, ?2, ?3, ?4, 0 WHERE EXISTS (SELECT 1 FROM notes WHERE id = ?1)
                    ON CONFLICT (note_id, day) DO UPDATE SET body_md = excluded.body_md, updated_at = excluded.updated_at, dirty = 0
                    WHERE excluded.updated_at > snapshots.updated_at
                    """, [s.NoteID, s.Day, s.BodyMd, s.UpdatedAt]);
            }
        });
    }

    public static string? SyncValue(string key) => TryQuery("SELECT value FROM sync_state WHERE key = ?1", [key], row => Text(row, 0)).FirstOrDefault();

    public static void SetSyncValue(string key, string? value) => Transaction(() =>
    {
        if (value != null) Run("INSERT OR REPLACE INTO sync_state (key, value) VALUES (?1, ?2)", [key, value]);
        else Run("DELETE FROM sync_state WHERE key = ?1", [key]);
    });

    /// Signing in to a different account: everything here goes up to it, and its notes come down from the start.
    public static void ResetSync() => Transaction(() =>
    {
        Run("UPDATE notes SET dirty = 1", []);
        Run("UPDATE folders SET dirty = 1", []);
        Run("UPDATE snapshots SET dirty = 1", []);
        Run("UPDATE images SET dirty = 1", []);
        Run("DELETE FROM sync_state WHERE key LIKE 'cursor.%'", []);
    });

    // Embeddings and icons: derived caches

    public static Dictionary<string, (double UpdatedAt, float[] Vector)> Vectors() => TryQuery("""
        SELECT e.note_id, e.updated_at, e.vector FROM embeddings e JOIN notes n ON n.id = e.note_id
        WHERE n.deleted_at IS NULL AND e.model = ?1
        """, [EmbeddingModel], row => (Id: Text(row, 0), UpdatedAt: row.GetDouble(1), Vector: Floats(Blob(row, 2))))
        .DistinctBy(row => row.Id).ToDictionary(row => row.Id, row => (row.UpdatedAt, row.Vector));

    public static void SaveVector(string id, double updatedAt, float[] vector)
    {
        var data = MemoryMarshal.AsBytes(vector.AsSpan()).ToArray();  // Float32, little-endian on every Mac and PC
        Transaction(() => Run("""
            INSERT INTO embeddings (note_id, model, updated_at, vector) VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT (note_id) DO UPDATE SET model = excluded.model, updated_at = excluded.updated_at, vector = excluded.vector
            """, [id, EmbeddingModel, updatedAt, data]));
    }

    public static byte[]? Icon(string key) => TryQuery("SELECT png FROM icons WHERE key = ?1", [key], row => Blob(row, 0)).FirstOrDefault();

    public static void SaveIcon(string key, byte[] png)
    {
        try { Transaction(() => Run("INSERT OR REPLACE INTO icons (key, png, fetched_at) VALUES (?1, ?2, ?3)", [key, png, Note.Now()])); }
        catch (Exception e) when (IsStorageError(e)) { }  // a cache: an icon that isn't kept is fetched again
    }

    /// The local day ("yyyy-MM-dd") of a time in milliseconds: the day a snapshot keeps.
    internal static string Day(double ms) => DateTimeOffset.UnixEpoch.AddMilliseconds(ms).ToLocalTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    // Ids come from the browser too, and name image files: only UUID characters (Swift's isHexDigit takes fullwidth ones too).
    static bool IsID(string id) => id.Length > 0 && id.All(c => c == '-' || char.IsAsciiHexDigit(c) || c is >= '０' and <= '９' or >= 'Ａ' and <= 'Ｆ' or >= 'ａ' and <= 'ｆ');
    static void Validate(string id) { if (!IsID(id)) throw new BadID(); }

    // SQLite

    static readonly Lock Gate = new();  // one connection, shared by every thread
    static readonly Lazy<SqliteConnection> Connection = new(() => Open(DatabasePath));  // a failed open fails every call, as on the Mac
    static SqliteConnection Db() => Connection.Value;

    internal static SqliteConnection Open(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        // Pooling off, so Dispose closes the file; a busy database retried for 5 s, as on the Mac, where Microsoft.Data.Sqlite would wait 30.
        var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false, DefaultTimeout = 5 }.ToString());
        try
        {
            db.Open();
            Exec(db, "PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON");
            Migrate(db);
            return db;
        }
        catch
        {
            db.Dispose();
            throw;
        }
    }

    internal const string SchemaV1 = """
        CREATE TABLE folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT REFERENCES folders (id) ON DELETE CASCADE);
        CREATE TABLE notes (
            id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK (kind IN ('app', 'url')), target TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '', body_md TEXT NOT NULL DEFAULT '',
            folder_id TEXT REFERENCES folders (id) ON DELETE SET NULL, pinned INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL, updated_at REAL NOT NULL, deleted_at REAL);
        CREATE INDEX notes_kind_target ON notes (kind, target);
        CREATE TABLE snapshots (note_id TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE, day TEXT NOT NULL,
            body_md TEXT NOT NULL, updated_at REAL NOT NULL, PRIMARY KEY (note_id, day));
        CREATE TABLE embeddings (note_id TEXT PRIMARY KEY REFERENCES notes (id) ON DELETE CASCADE, model TEXT NOT NULL,
            updated_at REAL NOT NULL, vector BLOB NOT NULL);
        CREATE TABLE tags (note_id TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE, tag TEXT NOT NULL, PRIMARY KEY (note_id, tag));
        CREATE TABLE links (from_note TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE,
            to_note TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE, PRIMARY KEY (from_note, to_note));
        CREATE TABLE attachments (id TEXT PRIMARY KEY, note_id TEXT NOT NULL REFERENCES notes (id) ON DELETE CASCADE,
            kind TEXT NOT NULL, path TEXT NOT NULL, meta_json TEXT);
        CREATE TABLE icons (key TEXT PRIMARY KEY, png BLOB NOT NULL, fetched_at REAL NOT NULL);
        """;

    /// The Mac's migrations, statement for statement: the version in PRAGMA user_version, re-checked under BEGIN IMMEDIATE as the app and host may start together.
    internal static void Migrate(SqliteConnection db)
    {
        Exec(db, "BEGIN IMMEDIATE");
        try
        {
            if (UserVersion(db) < 1)
            {
                Exec(db, SchemaV1);  // the Mac also imports its pre-SQLite JSON files here (D18); Windows never had them
                Exec(db, "PRAGMA user_version = 1");
            }
            if (UserVersion(db) < 2)
            {
                // Apple Intelligence's suggested title and tags per note version; kept apart from the user's own #tags.
                Exec(db, """
                    CREATE TABLE suggestions (note_id TEXT PRIMARY KEY REFERENCES notes (id) ON DELETE CASCADE,
                        updated_at REAL NOT NULL, title TEXT NOT NULL, tags_json TEXT NOT NULL);
                    PRAGMA user_version = 2;
                    """);
            }
            if (UserVersion(db) < 3)
            {
                // Cloud sync (D31): dirty rows changed here and not yet pushed; sync_state keeps pull cursors.
                Exec(db, """
                    ALTER TABLE notes ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1;
                    ALTER TABLE snapshots ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1;
                    CREATE INDEX notes_dirty ON notes (dirty) WHERE dirty = 1;
                    CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    PRAGMA user_version = 3;
                    """);
            }
            if (UserVersion(db) < 4)
            {
                // Colour labels, locked (encrypted) notes, and folders that sync (pinned and folder_id came with v1).
                Exec(db, """
                    ALTER TABLE notes ADD COLUMN color TEXT;
                    ALTER TABLE notes ADD COLUMN locked INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE folders ADD COLUMN updated_at REAL NOT NULL DEFAULT 0;
                    ALTER TABLE folders ADD COLUMN deleted_at REAL;
                    ALTER TABLE folders ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1;
                    PRAGMA user_version = 4;
                    """);
            }
            if (UserVersion(db) < 5)
            {
                // Pasted and dropped images (D53): the bytes are files in images/; a row per image so sync knows what to send.
                Exec(db, """
                    CREATE TABLE images (id TEXT PRIMARY KEY, type TEXT NOT NULL, created_at REAL NOT NULL,
                        dirty INTEGER NOT NULL DEFAULT 1);
                    PRAGMA user_version = 5;
                    """);
            }
            if (UserVersion(db) < 6)
            {
                // Starred notes (D73), synced like pinned.
                Exec(db, """
                    ALTER TABLE notes ADD COLUMN starred INTEGER NOT NULL DEFAULT 0;
                    PRAGMA user_version = 6;
                    """);
            }
            if (UserVersion(db) < 7)
            {
                // Ids are lowercase (D76): merge each uppercase/lowercase pair (the newer edit wins), moving rows that point at a note first; foreign keys are checked at COMMIT.
                Exec(db, """
                    PRAGMA defer_foreign_keys = ON;
                    DELETE FROM snapshots WHERE rowid IN (
                        SELECT l.rowid FROM snapshots u JOIN snapshots l ON l.note_id = lower(u.note_id) AND l.day = u.day
                        WHERE u.note_id <> l.note_id AND u.updated_at > l.updated_at);
                    UPDATE OR IGNORE snapshots SET note_id = lower(note_id) WHERE note_id <> lower(note_id);
                    DELETE FROM snapshots WHERE note_id <> lower(note_id);
                    UPDATE OR IGNORE embeddings SET note_id = lower(note_id) WHERE note_id <> lower(note_id);
                    DELETE FROM embeddings WHERE note_id <> lower(note_id);
                    UPDATE OR IGNORE suggestions SET note_id = lower(note_id) WHERE note_id <> lower(note_id);
                    DELETE FROM suggestions WHERE note_id <> lower(note_id);
                    UPDATE OR IGNORE tags SET note_id = lower(note_id) WHERE note_id <> lower(note_id);
                    DELETE FROM tags WHERE note_id <> lower(note_id);
                    UPDATE OR IGNORE links SET from_note = lower(from_note), to_note = lower(to_note)
                        WHERE from_note <> lower(from_note) OR to_note <> lower(to_note);
                    DELETE FROM links WHERE from_note <> lower(from_note) OR to_note <> lower(to_note);
                    UPDATE attachments SET note_id = lower(note_id) WHERE note_id <> lower(note_id);
                    UPDATE notes AS l SET kind = u.kind, target = u.target, title = u.title, body_md = u.body_md,
                        folder_id = u.folder_id, pinned = u.pinned, created_at = u.created_at, updated_at = u.updated_at,
                        deleted_at = u.deleted_at, dirty = u.dirty, color = u.color, locked = u.locked, starred = u.starred
                        FROM notes AS u WHERE u.id <> lower(u.id) AND l.id = lower(u.id) AND u.updated_at > l.updated_at;
                    DELETE FROM notes WHERE id <> lower(id) AND lower(id) IN (SELECT id FROM notes);
                    UPDATE notes SET id = lower(id) WHERE id <> lower(id);
                    UPDATE folders AS l SET name = u.name, updated_at = u.updated_at, deleted_at = u.deleted_at, dirty = u.dirty
                        FROM folders AS u WHERE u.id <> lower(u.id) AND l.id = lower(u.id) AND u.updated_at > l.updated_at;
                    UPDATE notes SET folder_id = lower(folder_id) WHERE folder_id <> lower(folder_id);
                    UPDATE folders SET parent_id = lower(parent_id) WHERE parent_id <> lower(parent_id);
                    DELETE FROM folders WHERE id <> lower(id) AND lower(id) IN (SELECT id FROM folders);
                    UPDATE folders SET id = lower(id) WHERE id <> lower(id);
                    PRAGMA user_version = 7;
                    """);
            }
            Exec(db, "COMMIT");
        }
        catch
        {
            Rollback(db);
            throw;
        }
    }

    static long UserVersion(SqliteConnection db)
    {
        using var command = Command(db, "PRAGMA user_version", []);
        return (long)command.ExecuteScalar()!;
    }

    static void Transaction(Action body)
    {
        lock (Gate)
        {
            var db = Db();
            Exec(db, "BEGIN IMMEDIATE");
            try
            {
                body();
                Exec(db, "COMMIT");
            }
            catch
            {
                Rollback(db);
                throw;
            }
        }
    }

    static void Rollback(SqliteConnection db)
    {
        try { Exec(db, "ROLLBACK"); }
        catch (SqliteException) { }  // the error that got here is the one to throw
    }

    static void Exec(SqliteConnection db, string sql) => Run(db, sql, []);

    static int Run(string sql, object?[] args) => Run(Db(), sql, args);

    static int Run(SqliteConnection db, string sql, object?[] args)
    {
        using var command = Command(db, sql, args);
        return command.ExecuteNonQuery();
    }

    /// Reads answer empty when the database can't be read, as the Mac's do (try?); a programming error still throws.
    static List<T> TryQuery<T>(string sql, object?[] args, Func<SqliteDataReader, T> row)
    {
        try
        {
            lock (Gate)
            {
                using var command = Command(Db(), sql, args);
                using var reader = command.ExecuteReader();
                List<T> rows = [];
                while (reader.Read()) rows.Add(row(reader));
                return rows;
            }
        }
        catch (Exception e) when (IsStorageError(e)) { return []; }
    }

    static bool IsStorageError(Exception e) => e is SqliteException or IOException or UnauthorizedAccessException;

    // The SQL numbers its parameters ?1, ?2…: Microsoft.Data.Sqlite binds by name and can't bind a bare "?".
    static SqliteCommand Command(SqliteConnection db, string sql, object?[] args)
    {
        var command = db.CreateCommand();
        command.CommandText = sql;
        for (var i = 0; i < args.Length; i++) command.Parameters.AddWithValue($"?{i + 1}", args[i] ?? DBNull.Value);
        return command;
    }

    static Note ReadNote(SqliteDataReader row) => new()
    {
        Id = Text(row, 0), Kind = NoteKind.FromRawValue(Text(row, 1)) ?? NoteKind.Url, Target = Text(row, 2), Label = Text(row, 3),
        Text = Text(row, 4), CreatedAt = row.GetDouble(5), UpdatedAt = row.GetDouble(6),
        Pinned = row.GetInt64(7) != 0, Starred = row.GetInt64(11) != 0,
        FolderID = row.IsDBNull(8) ? null : Text(row, 8),
        Color = NoteColor.FromRawValue(Text(row, 9)), Locked = row.GetInt64(10) != 0,
    };

    static string Text(SqliteDataReader row, int column) => row.IsDBNull(column) ? "" : row.GetString(column);

    static byte[] Blob(SqliteDataReader row, int column) => row.IsDBNull(column) ? [] : row.GetFieldValue<byte[]>(column);

    static float[] Floats(byte[] data) => MemoryMarshal.Cast<byte, float>(data).ToArray();

    // Data.write(options: .atomic): a reader never sees half an image.
    static void WriteAtomically(string path, byte[] data)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        File.WriteAllBytes(temporary, data);
        File.Move(temporary, path, overwrite: true);
    }
}
