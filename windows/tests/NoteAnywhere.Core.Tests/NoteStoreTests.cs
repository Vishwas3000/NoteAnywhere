namespace NoteAnywhere.Core.Tests;

/// Tests/MemoryNotesTests/SyncStoreTests.swift, plus soft deletes and pages, on the scratch store; the "NoteStore" collection runs them one at a time.
[Collection("NoteStore")]
public class NoteStoreTests
{
    public NoteStoreTests() => Assert.True(AppPaths.Data == Scratch.Dir, "would touch the real notes database");

    static string NewID() => Guid.NewGuid().ToString().ToUpperInvariant();  // Swift's UUID().uuidString, kept as given

    static NoteStore.CloudNote Remote(string id, string text, double at, double? deleted = null) => new(id, "url", "example.com", "", text, 1, at, deleted);

    static Note Loaded(string id) => NoteStore.LoadAll().Single(n => n.Id == id);

    /// Right-click → Color in the calendar is a text edit: it must reach the database.
    [Fact]
    public void EventColourIsSaved()
    {
        var note = new Note { Kind = NoteKind.App, Target = "demo.app", Label = "Demo", Text = "Dentist @2026-11-05 and gym @2026-11-06" };
        NoteStore.Save(note);
        var gym = Loaded(note.Id).Dates.Single(d => d.Day == "2026-11-06");
        var lines = note.Text.Split('\n');
        lines[gym.Line] = gym.Recolor(lines[gym.Line], NoteColor.Purple);
        NoteStore.Save(note with { Text = string.Join("\n", lines), UpdatedAt = note.UpdatedAt + 1 });
        Assert.Equal("Dentist @2026-11-05 and gym @2026-11-06{purple}", Loaded(note.Id).Text);
        Assert.Equal(NoteColor.Purple, Loaded(note.Id).Dates.Single(d => d.Day == "2026-11-06").Color);
    }

    [Fact]
    public void LocalEditsAreDirtyUntilPushed()
    {
        var id = NewID();
        NoteStore.Save(new Note { Id = id, Kind = NoteKind.Url, Target = "example.com", Label = "", Text = "a", CreatedAt = 1, UpdatedAt = 10 });
        var dirty = NoteStore.DirtyNotes().Where(n => n.Id == id).ToList();
        Assert.Equal(["a"], dirty.Select(n => n.BodyMd));
        Assert.Contains(NoteStore.DirtySnapshots(), s => s.NoteID == id);
        // Edited again before the push finished: stays dirty.
        NoteStore.Save(new Note { Id = id, Kind = NoteKind.Url, Target = "example.com", Label = "", Text = "b", CreatedAt = 1, UpdatedAt = 11 });
        NoteStore.MarkPushed(notes: dirty);
        Assert.Contains(NoteStore.DirtyNotes(), n => n.Id == id);
        NoteStore.MarkPushed(notes: [.. NoteStore.DirtyNotes().Where(n => n.Id == id)]);
        Assert.DoesNotContain(NoteStore.DirtyNotes(), n => n.Id == id);
    }

    [Fact]
    public void NewerWinsAndDeletesStick()
    {
        var id = NewID();
        NoteStore.ApplyRemote([Remote(id, "v1", 10)], []);
        Assert.Equal("v1", Loaded(id).Text);
        Assert.DoesNotContain(NoteStore.DirtyNotes(), n => n.Id == id);  // pulled rows aren't pushed back
        NoteStore.ApplyRemote([Remote(id, "old", 5)], []);
        Assert.Equal("v1", Loaded(id).Text);
        NoteStore.ApplyRemote([Remote(id, "v2", 20)], []);
        Assert.Equal("v2", Loaded(id).Text);
        // Deleted on another device, even though that copy is older than ours.
        NoteStore.ApplyRemote([Remote(id, "x", 15, deleted: 15)], []);
        Assert.DoesNotContain(NoteStore.LoadAll(), n => n.Id == id);
        NoteStore.ApplyRemote([Remote(id, "back", 30)], []);
        Assert.DoesNotContain(NoteStore.LoadAll(), n => n.Id == id);  // a later edit can't revive it
    }

    [Fact]
    public void PinsColoursAndFoldersArriveWithTheirNotes()
    {
        string note = NewID(), folder = NewID(), missing = NewID();
        var pinned = Remote(note, "x", 10) with { Pinned = true, Starred = true, Color = "blue", FolderID = folder };
        var orphan = Remote(NewID(), "y", 10) with { FolderID = missing };  // its folder hasn't arrived: lands in All Notes rather than failing
        NoteStore.ApplyRemote([pinned, orphan], [], folders: [new(folder, "Work", 1)]);
        var local = Loaded(note);
        Assert.True(local.Pinned && local.Starred && local.Color == NoteColor.Blue && local.FolderID == folder);
        Assert.Null(Loaded(orphan.Id).FolderID);
        Assert.Contains(NoteStore.Folders(), f => f.Id == folder && f.Name == "Work");
        // A local pin is a change to push, without counting as an edit.
        NoteStore.SaveMeta(local with { Pinned = false, Starred = false });
        var pushed = NoteStore.DirtyNotes().Single(n => n.Id == note);
        Assert.True(pushed.Pinned == false && pushed.Starred == false && pushed.UpdatedAt == 11);
        Assert.False(Loaded(note).Starred);
    }

    [Fact]
    public void LockingLeavesNoReadableCopy()
    {
        var id = NewID();
        NoteStore.Save(new Note { Id = id, Kind = NoteKind.Url, Target = "bank.example", Label = "", Text = "pin 1234", CreatedAt = 1, UpdatedAt = 10 });
        NoteStore.SaveVector(id, 10, [1, 0]);
        var sealedText = "mnlock:v1:" + Convert.ToBase64String("salt nonce ciphertext tag"u8);  // NoteLock's envelope; only its prefix matters here
        NoteStore.SetLocked(id, sealedText, locked: true);
        var note = Loaded(id);
        Assert.True(note.Locked && note.Text == sealedText && note.Title == "Locked Note" && note.Tags.Count == 0);
        Assert.All(NoteStore.LoadHistory().Where(s => s.Note.Id == id), s => Assert.DoesNotContain("1234", s.Note.Text));
        Assert.False(NoteStore.Vectors().ContainsKey(id));
        Assert.DoesNotContain(NoteStore.NotesUnder("bank.example"), n => n.Id == id);  // the browser never sees it
        // A browser tab that loaded the note before it was locked can't write readable text over it.
        NoteStore.Save(new Note { Id = id, Kind = NoteKind.Url, Target = "bank.example", Label = "", Text = "pin 1234", CreatedAt = 1, UpdatedAt = 99_999_999_999_999 });
        Assert.Equal(sealedText, Loaded(id).Text);
    }

    [Fact]
    public void ImagesSyncAsFilesPlusRows()
    {
        byte[] png = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3];
        var id = NoteStore.SaveImage(png, "image/png");
        var dirty = NoteStore.DirtyImages(limit: 10_000).Where(i => i.Id == id).ToList();
        Assert.Equal(["image/png"], dirty.Select(i => i.Type));
        Assert.False(NoteStore.WantsImage(dirty[0]));  // this device already has it
        NoteStore.MarkPushed(images: dirty);
        Assert.DoesNotContain(NoteStore.DirtyImages(limit: 10_000), i => i.Id == id);

        // From another device: wanted until its bytes are written, then shows like a local one and isn't pushed back.
        var remote = new NoteStore.CloudImage(Guid.NewGuid().ToString(), "image/jpeg", 5);
        Assert.True(NoteStore.WantsImage(remote));
        NoteStore.SaveRemoteImage(remote, [0xFF, 0xD8, 9]);
        Assert.Equal([0xFF, 0xD8, 9], NoteStore.Image(remote.Id)?.Data);
        Assert.Equal("image/jpeg", NoteStore.Image(remote.Id)?.Type);
        Assert.False(NoteStore.WantsImage(remote));
        Assert.DoesNotContain(NoteStore.DirtyImages(limit: 10_000), i => i.Id == remote.Id);

        // Malformed rows are skipped, and bytes that aren't an image notes hold are refused.
        Assert.False(NoteStore.WantsImage(new("../notes", "image/png", 1)));
        Assert.False(NoteStore.WantsImage(new(NewID(), "text/html", 1)));
        var big = new NoteStore.CloudImage(NewID(), "image/png", 1);
        Assert.Throws<NoteStore.ImageError>(() => NoteStore.SaveRemoteImage(big, new byte[NoteStore.MaxImageBytes + 1]));
        Assert.Null(NoteStore.Image(big.Id));
        Assert.Throws<NoteStore.BadID>(() => NoteStore.SaveRemoteImage(new("../notes", "image/png", 1), [1]));

        // Another account: every image goes up again.
        NoteStore.ResetSync();
        Assert.Superset(new HashSet<string> { id, remote.Id }, NoteStore.DirtyImages(limit: 10_000).Select(i => i.Id).ToHashSet());
    }

    [Fact]
    public void SnapshotsNeedTheirNoteAndCursorsPersist()
    {
        var id = NewID();
        var snap = new NoteStore.CloudSnapshot(id, "2026-10-01", "s", 3);
        NoteStore.ApplyRemote([], [snap]);  // note not here yet: skipped, not an error
        NoteStore.ApplyRemote([Remote(id, "n", 3)], [snap]);
        Assert.Contains(NoteStore.LoadHistory(), s => s.Note.Id == id && s.Day == "2026-10-01");
        NoteStore.SetSyncValue("cursor.notes", "42");
        Assert.Equal("42", NoteStore.SyncValue("cursor.notes"));
        NoteStore.ResetSync();
        Assert.Null(NoteStore.SyncValue("cursor.notes"));
        Assert.Contains(NoteStore.DirtyNotes(limit: 10_000), n => n.Id == id);
    }

    /// D76: the server's uuid columns answer in lowercase; a note made here must come back as itself.
    [Fact]
    public void ANotePulledBackStaysOneNote()
    {
        var note = new Note { Kind = NoteKind.Url, Target = "example.com", Label = "", Text = "x" };
        NoteStore.Save(note);
        Assert.Equal(note.Id.ToLowerInvariant(), note.Id);
        NoteStore.ApplyRemote([Remote(note.Id.ToLowerInvariant(), "x", note.UpdatedAt + 1)], []);
        Assert.Single(NoteStore.LoadAll(), n => n.Id.Equals(note.Id, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void DeletesAreSoft()
    {
        var note = new Note { Kind = NoteKind.Url, Target = "soft.example/page", Label = "", Text = "Gone soon #soft @2026-11-25", CreatedAt = 1, UpdatedAt = 10 };
        NoteStore.Save(note);
        NoteStore.SaveVector(note.Id, 10, [1, 0]);
        NoteStore.MarkPushed(notes: [.. NoteStore.DirtyNotes(limit: 10_000).Where(n => n.Id == note.Id)]);
        NoteStore.Delete(note.Id);

        // The row stays, text and all, marked deleted and dirty, so sync carries the delete.
        var tombstone = NoteStore.DirtyNotes(limit: 10_000).Single(n => n.Id == note.Id);
        Assert.NotNull(tombstone.DeletedAt);
        Assert.Equal(tombstone.DeletedAt, tombstone.UpdatedAt);
        Assert.Equal(note.Text, tombstone.BodyMd);
        // Every read skips it.
        Assert.DoesNotContain(NoteStore.LoadAll(), n => n.Id == note.Id);
        Assert.DoesNotContain(NoteStore.NotesUnder("soft.example"), n => n.Id == note.Id);
        Assert.DoesNotContain(NoteStore.LoadHistory(), s => s.Note.Id == note.Id);
        Assert.False(NoteStore.Vectors().ContainsKey(note.Id));
        // Saving it again, pinning it or deleting it again changes nothing.
        NoteStore.Save(note with { Text = "back", UpdatedAt = 99 });
        NoteStore.SaveMeta(note with { Pinned = true });
        NoteStore.Delete(note.Id);
        Assert.DoesNotContain(NoteStore.LoadAll(), n => n.Id == note.Id);
        Assert.Equal(tombstone, NoteStore.DirtyNotes(limit: 10_000).Single(n => n.Id == note.Id));
        // Ids are checked before any SQL: they come from the browser and name image files.
        Assert.Throws<NoteStore.BadID>(() => NoteStore.Delete("../notes"));
        Assert.Throws<NoteStore.BadID>(() => NoteStore.Delete(""));
    }

    [Fact]
    public void ADeletedFolderIsATombstoneAndLetsItsNotesGo()
    {
        var folder = new Folder { Id = NewID(), Name = "Trips" };
        NoteStore.SaveFolder(folder);
        var note = new Note { Kind = NoteKind.Url, Target = "", Label = "", Text = "Packing list" };
        NoteStore.Save(note);
        NoteStore.SaveMeta(note with { FolderID = folder.Id });
        var filed = Loaded(note.Id);
        Assert.Equal(folder.Id, filed.FolderID);

        NoteStore.DeleteFolder(folder.Id);
        Assert.DoesNotContain(NoteStore.Folders(), f => f.Id == folder.Id);
        Assert.NotNull(NoteStore.DirtyFolders().Single(f => f.Id == folder.Id).DeletedAt);  // kept, for sync
        var back = Loaded(note.Id);
        Assert.Null(back.FolderID);  // back in All Notes, not deleted with it
        Assert.Equal(filed.UpdatedAt + 1, back.UpdatedAt);
        NoteStore.SaveMeta(back with { FolderID = folder.Id });  // nothing can be filed in it now
        Assert.Null(Loaded(note.Id).FolderID);
    }

    [Fact]
    public void APageShowsItsOwnNotesAndThoseUnderIt()
    {
        string[] targets = ["under.example", "under.example/a", "under.example/a/b", "under.example/ab", "under.example0", "under.examples/x"];
        for (var i = 0; i < targets.Length; i++)
            NoteStore.Save(new Note { Kind = NoteKind.Url, Target = targets[i], Label = "", Text = targets[i], CreatedAt = i + 1 });
        NoteStore.Save(new Note { Kind = NoteKind.App, Target = "under.example/a", Label = "", Text = "an app's note" });
        Assert.Equal(["under.example", "under.example/a", "under.example/a/b", "under.example/ab"], NoteStore.NotesUnder("under.example/").Select(n => n.Target));
        Assert.Equal(["under.example/a", "under.example/a/b"], NoteStore.NotesUnder("under.example/a").Select(n => n.Target));
    }

    [Fact]
    public void ASaveThatChangesNothingTakesNoSnapshot()
    {
        var app = new Note { Kind = NoteKind.App, Target = "demo.app", Label = "", Text = "an app's note", UpdatedAt = 10 };
        NoteStore.Save(app);
        NoteStore.Save(app with { Kind = NoteKind.Url, Text = "the browser reusing its id", UpdatedAt = 20 });
        Assert.Equal("an app's note", Loaded(app.Id).Text);
        Assert.Equal(["an app's note"], NoteStore.LoadHistory().Where(s => s.Note.Id == app.Id).Select(s => s.Note.Text));
    }
}

/// Notes written on Windows keep the Mac's line breaks, so they read the same on every device.
public class WindowsLineEndingTests
{
    [Fact]
    public void WindowsLineBreaksAreStoredAsTheMacs()
    {
        var note = new Note { Kind = NoteKind.Url, Target = "", Label = "", Text = "Groceries\r\n- [ ] milk\r\n- [ ] eggs" };
        NoteStore.Save(note);
        var saved = NoteStore.LoadAll().Single(n => n.Id == note.Id);
        Assert.Equal("Groceries\n- [ ] milk\n- [ ] eggs", saved.Text);
        Assert.Equal("Groceries", saved.Title);
        NoteStore.Delete(note.Id);
    }
}
