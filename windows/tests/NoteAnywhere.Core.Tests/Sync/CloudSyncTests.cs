using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using NoteAnywhere.Core.Crypto;
using NoteAnywhere.Core.Sync;
using NoteAnywhere.Core.Tests.Crypto;

namespace NoteAnywhere.Core.Tests.Sync;

/// SyncCloud.swift's protocol, request for request, against a fake Supabase: signing in, the session, the vault, and
/// rounds that push sealed rows and pull opened ones. They use the shared scratch store, so they run one at a time.
[Collection("NoteStore")]
public class CloudSyncTests : IDisposable
{
    const string Passphrase = "correct horse battery";

    public CloudSyncTests() => Assert.True(AppPaths.Data == Scratch.Dir, "would touch the real notes database");

    // Signing in to another account marks everything for upload: leave nothing dirty for the store's other tests.
    public void Dispose() => NoteStore.MarkPushed(NoteStore.DirtyNotes(int.MaxValue), NoteStore.DirtySnapshots(int.MaxValue),
        NoteStore.DirtyFolders(), NoteStore.DirtyImages(int.MaxValue));

    /// A device signed in with the emailed code and the account's passphrase, after its first round.
    static async Task<CloudSync> Device(FakeSupabase fake, ISecretStore? secrets = null)
    {
        var sync = new CloudSync(secrets ?? new MemorySecretStore(), fake);
        await sync.SendLink(fake.Email);
        await sync.Verify(FakeSupabase.Code);
        await (sync.Vault == CloudSync.VaultStep.Create ? sync.CreateVault(Passphrase) : sync.EnterVault(Passphrase));
        await sync.Sync(pull: true);  // this account's first round here: every note goes up, and comes back
        Assert.Null(sync.Error);
        Assert.True(sync.Active);
        fake.ClearRequests();
        return sync;
    }

    static byte[] VaultKey(FakeSupabase fake)
    {
        var vault = fake.Rows("vaults").Single();
        return SyncVault.UnwrapKey(Passphrase, (string)vault["salt"]!, (string)vault["wrapped"]!);
    }

    /// A note as the Mac pushes it: every column, the words sealed.
    static JsonObject NoteRow(string id, string text, byte[] key, double at, double? deleted = null) => new()
    {
        ["id"] = id, ["kind"] = "url", ["target"] = SyncVault.Seal("example.com", key), ["label"] = SyncVault.Seal("", key),
        ["body_md"] = SyncVault.Seal(text, key), ["created_at"] = 1.0, ["updated_at"] = at, ["deleted_at"] = deleted,
        ["pinned"] = false, ["folder_id"] = null, ["color"] = null, ["locked"] = false, ["starred"] = false,
    };

    static string NewID() => Guid.NewGuid().ToString();

    static Note Local(string id) => NoteStore.LoadAll().Single(n => n.Id == id);

    static string ServerText(FakeSupabase fake, string id, byte[] key) => SyncVault.Open((string)fake.Row("notes", id)["body_md"]!, key);

    static async Task Eventually(Func<bool> condition)
    {
        for (var waited = 0; !condition() && waited < 10_000; waited += 20) await Task.Delay(20);
        Assert.True(condition());
    }

    [Fact]
    public async Task SignsInWithTheEmailedCode()
    {
        var fake = new FakeSupabase();
        var secrets = new MemorySecretStore();
        var sync = new CloudSync(secrets, fake);
        await sync.SendLink("  Ada@Example.COM ");
        Assert.Equal("POST /auth/v1/otp?redirect_to=memorynotes%3A%2F%2Fauth-callback", fake.Requests.Single().ToString());
        Assert.Equal("""{"email":"ada@example.com","create_user":true}""", fake.Requests[0].Text);
        Assert.False(fake.Requests[0].Headers.ContainsKey("Authorization"));
        Assert.Equal("ada@example.com", sync.PendingEmail);

        await sync.Verify("8765 4321");
        Assert.Equal("Token has expired or is invalid", sync.Error);
        Assert.Null(sync.Email);
        Assert.Equal("ada@example.com", sync.PendingEmail);  // the code can be typed again

        await sync.Verify("1234-5678");
        Assert.Equal("""{"type":"email","email":"ada@example.com","token":"12345678"}""", fake.Requests[2].Text);
        Assert.Null(sync.Error);
        Assert.Equal("ada@example.com", sync.Email);
        Assert.Null(sync.PendingEmail);
        Assert.False(sync.Busy);
        // The account's first device: no vault yet, so it's asked to make one, and nothing syncs before that.
        Assert.Equal("GET /rest/v1/vaults?select=salt,wrapped", fake.Requests[3].ToString());
        Assert.Equal("Bearer access-1", fake.Requests[3].Headers["Authorization"]);
        Assert.Equal(CloudSync.VaultStep.Create, sync.Vault);
        Assert.False(sync.Active);
        Assert.All(fake.Requests, r => Assert.Equal(CloudSync.PublishableKey, r.Headers["apikey"]));
        fake.ClearRequests();
        await sync.Sync(pull: true);
        Assert.Empty(fake.Requests);
        // The session is kept: the next launch is signed in.
        Assert.Equal("ada@example.com", new CloudSync(secrets, fake).Email);
    }

    [Fact]
    public async Task SignsInFromTheEmailsLinkOrGoogles()
    {
        Assert.Equal("https://strhaqnvxtpmlvcwkkne.supabase.co/auth/v1/authorize?provider=google&redirect_to=memorynotes%3A%2F%2Fauth-callback",
            CloudSync.GoogleUrl);
        var fake = new FakeSupabase();
        var sync = new CloudSync(new MemorySecretStore(), fake);
        await sync.Handle("memorynotes://auth-callback?error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired");
        Assert.Equal("Email link is invalid or has expired", sync.Error);
        await sync.Handle("memorynotes://auth-callback#error=access_denied&error_description=Email%20link%20is%20invalid%20or%20has%20expired");
        Assert.Equal("Email link is invalid or has expired", sync.Error);
        await sync.Handle("memorynotes://auth-callback#type=magiclink");
        Assert.Equal("That sign-in link didn't work. Send a new one.", sync.Error);
        await sync.Handle("memorynotes://elsewhere#access_token=a&refresh_token=b");  // not a sign-in link
        Assert.Empty(fake.Requests);
        Assert.Null(sync.Email);

        var session = fake.Issue();
        string access = (string)session["access_token"]!, refresh = (string)session["refresh_token"]!;
        await sync.Handle($"memorynotes://auth-callback#access_token={access}&expires_at={(long)session["expires_at"]!}" +
                          $"&expires_in=3600&refresh_token={refresh}&token_type=bearer&type=magiclink");
        Assert.Null(sync.Error);
        Assert.Equal("ada@example.com", sync.Email);
        Assert.Equal("GET /auth/v1/user", fake.Requests[0].ToString());
        Assert.Equal($"Bearer {access}", fake.Requests[0].Headers["Authorization"]);
        Assert.Equal(CloudSync.VaultStep.Create, sync.Vault);
    }

    [Fact]
    public async Task RefreshesTheSessionAMinuteBeforeItEnds()
    {
        var fake = new FakeSupabase();
        var secrets = new MemorySecretStore();
        await Device(fake, secrets);
        // The saved session as it is 59 minutes on: due.
        var saved = JsonNode.Parse(secrets.Get("session")!)!;
        saved["expires_at"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 59;
        secrets.Set("session", Encoding.UTF8.GetBytes(saved.ToJsonString()));
        var sync = new CloudSync(secrets, fake);  // the next launch
        Assert.True(sync.Active);
        await sync.Sync(pull: true);
        Assert.Null(sync.Error);
        var requests = fake.Requests;
        Assert.Equal("POST /auth/v1/token?grant_type=refresh_token", requests[0].ToString());
        Assert.Equal("""{"refresh_token":"refresh-1"}""", requests[0].Text);
        Assert.Equal(4, requests.Count(r => r.Method == "GET"));
        Assert.All(requests.Skip(1), r => Assert.Equal("Bearer access-2", r.Headers["Authorization"]));
        // The new session is kept and lasts: the launch after needs no refresh.
        Assert.Equal("refresh-2", (string?)JsonNode.Parse(secrets.Get("session")!)!["refresh_token"]);
        fake.ClearRequests();
        await new CloudSync(secrets, fake).Sync(pull: true);
        Assert.DoesNotContain(fake.Requests, r => r.Path == "/auth/v1/token");
    }

    [Fact]
    public async Task ARejectedSessionSignsOutButKeepsTheVaultKey()
    {
        var fake = new FakeSupabase();
        var secrets = new MemorySecretStore();
        var sync = await Device(fake, secrets);
        fake.Failures["GET /rest/v1/notes"] = (401, """{"code":"PGRST303","details":null,"hint":null,"message":"JWT expired"}""");
        await sync.Sync(pull: true);
        Assert.Equal("JWT expired", sync.Error);
        Assert.Null(sync.Email);
        Assert.False(sync.Active);
        Assert.Null(secrets.Get("session"));
        Assert.NotNull(SyncVault.SavedKey(secrets, fake.UserID));
        // Signing in again goes straight back to syncing, with no passphrase.
        await sync.SendLink(fake.Email);
        await sync.Verify(FakeSupabase.Code);
        Assert.Equal(CloudSync.VaultStep.Ready, sync.Vault);
        Assert.True(sync.Active);
    }

    [Fact]
    public async Task TheVaultOpensOnlyWithItsPassphrase()
    {
        var fake = new FakeSupabase();
        var first = new CloudSync(new MemorySecretStore(), fake);
        await first.SendLink(fake.Email);
        await first.Verify(FakeSupabase.Code);
        fake.ClearRequests();
        await first.CreateVault(Passphrase);
        Assert.Null(first.Error);
        Assert.Equal(CloudSync.VaultStep.Ready, first.Vault);
        Assert.True(first.Active);
        var create = fake.Requests.Single();
        Assert.Equal("POST /rest/v1/vaults", create.ToString());
        Assert.Equal("return=minimal", create.Headers["Prefer"]);  // an insert, never an upsert: it can't replace another device's key
        var row = create.Json!.AsArray().Single()!.AsObject();
        Assert.Equal(["salt", "wrapped"], row.Select(column => column.Key));
        Assert.Equal(16, Convert.FromBase64String((string)row["salt"]!).Length);
        var key = VaultKey(fake);
        Assert.Equal(32, key.Length);

        // Another device is asked for it; a wrong one fails cleanly and keeps nothing.
        var secrets = new MemorySecretStore();
        var second = new CloudSync(secrets, fake);
        await second.SendLink(fake.Email);
        await second.Verify(FakeSupabase.Code);
        Assert.Equal(CloudSync.VaultStep.Enter, second.Vault);
        await second.EnterVault("not the passphrase");
        Assert.Equal("That passphrase doesn't open your synced notes.", second.Error);
        Assert.Equal(CloudSync.VaultStep.Enter, second.Vault);
        Assert.False(second.Active);
        Assert.False(second.Busy);
        Assert.Null(SyncVault.SavedKey(secrets, fake.UserID));
        await second.EnterVault(Passphrase);
        Assert.Null(second.Error);
        Assert.True(second.Active);
        Assert.Equal(key, SyncVault.SavedKey(secrets, fake.UserID));

        // A device that makes a vault too (it raced the first) is told to enter that one instead.
        var third = new CloudSync(new MemorySecretStore(), fake);
        await third.SendLink(fake.Email);
        await third.Verify(FakeSupabase.Code);
        await third.CreateVault("another passphrase");
        Assert.Equal("Another device already set a sync passphrase. Enter that one.", third.Error);
        Assert.Equal(CloudSync.VaultStep.Enter, third.Vault);
        Assert.False(third.Active);
        Assert.Equal(key, VaultKey(fake));  // still the first device's key
    }

    [Fact]
    public async Task PushesWhatChangedHereSealed()
    {
        var fake = new FakeSupabase();
        var sync = await Device(fake);
        var key = VaultKey(fake);
        var folder = new Folder { Name = "Launch plans" };
        NoteStore.SaveFolder(folder);
        var note = new Note { Kind = NoteKind.App, Target = "com.tinyspeck.slackmacgap/Acme/Alex Rivera (DM)", Label = "Slack", Text = "secret plan #launch" };
        NoteStore.Save(note);
        NoteStore.SaveMeta(note with { FolderID = folder.Id, Pinned = true });
        await sync.Sync(pull: false);
        Assert.Null(sync.Error);
        // Folders before the notes in them, notes before their snapshots: upserts on each table's key,
        Assert.Equal(["POST /rest/v1/folders?on_conflict=id", "POST /rest/v1/notes?on_conflict=id", "POST /rest/v1/snapshots?on_conflict=note_id,day"],
            fake.Requests.Select(r => r.ToString()));
        Assert.All(fake.Requests, r => Assert.Equal("resolution=merge-duplicates,return=minimal", r.Headers["Prefer"]));
        Assert.All(fake.Requests, r => Assert.Equal($"Bearer {fake.AccessToken}", r.Headers["Authorization"]));

        // Every column, nulls too (PostgREST takes a batch's columns from its first row); the words only sealed.
        var row = fake.Requests[1].Json!.AsArray().Single()!.AsObject();
        Assert.Equal(["id", "kind", "target", "label", "body_md", "created_at", "updated_at", "deleted_at", "pinned", "folder_id", "color", "locked", "starred"],
            row.Select(column => column.Key));
        Assert.Null(row["deleted_at"]);
        Assert.Null(row["color"]);
        Assert.Equal(note.Id, (string?)row["id"]);
        Assert.Equal("app", (string?)row["kind"]);
        Assert.Equal(folder.Id, (string?)row["folder_id"]);
        Assert.True((bool)row["pinned"]! && !(bool)row["locked"]! && !(bool)row["starred"]!);
        Assert.Equal(Local(note.Id).UpdatedAt, (double)row["updated_at"]!);
        foreach (var (column, plain) in new[] { ("target", note.Target), ("label", note.Label), ("body_md", note.Text) })
        {
            var sealedText = (string)row[column]!;
            Assert.StartsWith("mne2e:v1:", sealedText);
            Assert.DoesNotContain("secret", sealedText);
            Assert.DoesNotContain("Alex", sealedText);
            Assert.Equal(plain, SyncVault.Open(sealedText, key));
        }
        var folderRow = fake.Requests[0].Json!.AsArray().Single()!.AsObject();
        Assert.Equal(["id", "name", "updated_at", "deleted_at"], folderRow.Select(column => column.Key));
        Assert.Equal("Launch plans", SyncVault.Open((string)folderRow["name"]!, key));
        var snapshot = fake.Requests[2].Json!.AsArray().Single()!.AsObject();
        Assert.Equal(["note_id", "day", "body_md", "updated_at"], snapshot.Select(column => column.Key));
        Assert.Equal(note.Text, SyncVault.Open((string)snapshot["body_md"]!, key));

        // Pushed rows are clean: nothing more goes up.
        fake.ClearRequests();
        await sync.Sync(pull: false);
        Assert.Empty(fake.Requests);
    }

    [Fact]
    public async Task PullsWhatOtherDevicesPushedOpened()
    {
        var fake = new FakeSupabase();
        var sync = await Device(fake);
        var key = VaultKey(fake);
        string folder = NewID(), note = NewID();
        var cursors = new[] { "folders", "notes", "snapshots", "images" }.Select(table => NoteStore.SyncValue($"cursor.{table}") ?? "0").ToList();
        fake.Put("folders", new JsonObject { ["id"] = folder, ["name"] = SyncVault.Seal("From the Mac", key), ["updated_at"] = 5.0, ["deleted_at"] = null });
        var row = NoteRow(note, "# Written on the Mac\nwith a #tag", key, at: 10);
        row["target"] = SyncVault.Seal("github.com/vercel/next.js", key);
        row["label"] = SyncVault.Seal("GitHub", key);
        row["folder_id"] = folder;
        row["color"] = "blue";
        row["starred"] = true;
        fake.Put("notes", row);
        fake.Put("snapshots", new JsonObject { ["note_id"] = note, ["day"] = "2026-11-20", ["body_md"] = SyncVault.Seal("As it was that day", key), ["updated_at"] = 9.0 });
        await sync.Sync(pull: true);
        Assert.Null(sync.Error);
        // Each table after its cursor, in seq order, 500 at a time.
        Assert.Equal([
            $"GET /rest/v1/folders?select=id,name,updated_at,deleted_at,seq&seq=gt.{cursors[0]}&order=seq.asc&limit=500",
            $"GET /rest/v1/notes?select=id,kind,target,label,body_md,created_at,updated_at,deleted_at,pinned,folder_id,color,locked,starred,seq&seq=gt.{cursors[1]}&order=seq.asc&limit=500",
            $"GET /rest/v1/snapshots?select=note_id,day,body_md,updated_at,seq&seq=gt.{cursors[2]}&order=seq.asc&limit=500",
            $"GET /rest/v1/images?select=id,type,created_at,seq&seq=gt.{cursors[3]}&order=seq.asc&limit=500"],
            fake.Requests.Select(r => r.ToString()));
        var local = Local(note);
        Assert.Equal("# Written on the Mac\nwith a #tag", local.Text);
        Assert.Equal("github.com/vercel/next.js", local.Target);
        Assert.Equal("GitHub", local.Label);
        Assert.Equal(folder, local.FolderID);
        Assert.Equal(NoteColor.Blue, local.Color);
        Assert.True(local.Starred);
        Assert.Contains(NoteStore.Folders(), f => f.Id == folder && f.Name == "From the Mac");
        Assert.Contains(NoteStore.LoadHistory(), s => s.Note.Id == note && s.Day == "2026-11-20" && s.Note.Text == "As it was that day");
        Assert.DoesNotContain(NoteStore.DirtyNotes(int.MaxValue), n => n.Id == note);  // not pushed back
        // The cursors moved past them.
        Assert.Equal(fake.Row("notes", note)["seq"]!.ToJsonString(), NoteStore.SyncValue("cursor.notes"));
        Assert.Equal(fake.Seq.ToString(), NoteStore.SyncValue("cursor.snapshots"));

        // A row this vault key can't open stops the round before any of it lands, and the cursor stays for the next.
        var stranger = NewID();
        fake.Put("notes", NoteRow(stranger, "sealed with another key", RandomNumberGenerator.GetBytes(32), at: 10));
        var cursor = NoteStore.SyncValue("cursor.notes");
        await sync.Sync(pull: true);
        Assert.Equal("A synced note can't be read with this passphrase.", sync.Error);
        Assert.DoesNotContain(NoteStore.LoadAll(), n => n.Id == stranger);
        Assert.Equal(cursor, NoteStore.SyncValue("cursor.notes"));
    }

    [Fact]
    public async Task BigSyncsGoInBatches()
    {
        var fake = new FakeSupabase();
        var sync = await Device(fake);
        var key = VaultKey(fake);
        var cursor = long.Parse(NoteStore.SyncValue("cursor.notes") ?? "0");
        for (var i = 0; i < 501; i++) fake.Put("notes", NoteRow(NewID(), $"from the Mac {i}", key, at: 10));
        for (var i = 0; i < 201; i++) NoteStore.Save(new Note { Kind = NoteKind.Url, Target = "", Label = "", Text = $"from here {i}" });
        await sync.Sync(pull: true);
        Assert.Null(sync.Error);
        // Up: notes 200 at a time, snapshots 500 at a time.
        Assert.Equal([200, 1], fake.Requests.Where(r => r.ToString() == "POST /rest/v1/notes?on_conflict=id").Select(r => r.Json!.AsArray().Count));
        Assert.Equal([201], fake.Requests.Where(r => r.ToString() == "POST /rest/v1/snapshots?on_conflict=note_id,day").Select(r => r.Json!.AsArray().Count));
        // Down: 500 rows at a time, the next page after the last row's seq.
        var after = fake.Rows("notes").Select(row => (long)row["seq"]!).Where(seq => seq > cursor).Order().ToList();
        Assert.Equal([$"seq=gt.{cursor}", $"seq=gt.{after[499]}"], fake.Requests.Where(r => r.Method == "GET" && r.Path == "/rest/v1/notes")
            .Select(r => r.Query.Split('&').Single(part => part.StartsWith("seq=", StringComparison.Ordinal))));
        Assert.Equal(after[^1].ToString(), NoteStore.SyncValue("cursor.notes"));
        Assert.Equal(501, NoteStore.LoadAll().Count(n => n.Text.StartsWith("from the Mac ", StringComparison.Ordinal)));
    }

    [Fact]
    public async Task TheNewerEditWinsAndDeletesStick()
    {
        var fake = new FakeSupabase();
        var sync = await Device(fake);
        var key = VaultKey(fake);
        string mine = NewID(), theirs = NewID(), gone = NewID();
        foreach (var id in new[] { mine, theirs, gone }) fake.Put("notes", NoteRow(id, "v1", key, at: 10));
        await sync.Sync(pull: true);
        Assert.Equal("v1", Local(mine).Text);

        // Offline, both edit: this device the first note later than the other device, the second earlier; the other
        // device deletes the third, which this one then edits.
        NoteStore.Save(Local(mine) with { Text = "mine, later", UpdatedAt = 30 });
        NoteStore.Save(Local(theirs) with { Text = "mine, earlier", UpdatedAt = 15 });
        NoteStore.Save(Local(gone) with { Text = "edited after the delete", UpdatedAt = 40 });
        fake.Put("notes", NoteRow(mine, "theirs, earlier", key, at: 20));
        fake.Put("notes", NoteRow(theirs, "theirs, later", key, at: 25));
        fake.Put("notes", NoteRow(gone, "v1", key, at: 22, deleted: 22));
        await sync.Sync(pull: true);
        Assert.Null(sync.Error);
        Assert.Equal("mine, later", Local(mine).Text);
        Assert.Equal("mine, later", ServerText(fake, mine, key));
        Assert.Equal("theirs, later", Local(theirs).Text);
        Assert.Equal("theirs, later", ServerText(fake, theirs, key));
        Assert.DoesNotContain(NoteStore.LoadAll(), n => n.Id == gone);  // deleted there, so deleted here, edit or not
        Assert.NotNull(fake.Row("notes", gone)["deleted_at"]);

        // A delete here goes up as a tombstone; the note doesn't come back with a later edit from a device that missed it.
        NoteStore.Delete(mine);
        await sync.Sync(pull: true);
        Assert.NotNull(fake.Row("notes", mine)["deleted_at"]);
        fake.Put("notes", NoteRow(mine, "edited where the delete hadn't arrived", key, at: 9e15));
        await sync.Sync(pull: true);
        Assert.Null(sync.Error);
        Assert.DoesNotContain(NoteStore.LoadAll(), n => n.Id == mine);
    }

    [Fact]
    public async Task ImagesTravelSealedThroughStorage()
    {
        var fake = new FakeSupabase();
        var sync = await Device(fake);
        var key = VaultKey(fake);
        byte[] png = [0x89, .. "PNG secret screenshot"u8];
        var mine = NoteStore.SaveImage(png, "image/png");
        await sync.Sync(pull: false);
        Assert.Null(sync.Error);
        // The sealed bytes to the account's folder in Storage first, then the row that says they're there.
        Assert.Equal([$"POST /storage/v1/object/images/{fake.UserID}/{mine}", "POST /rest/v1/images?on_conflict=id"], fake.Requests.Select(r => r.ToString()));
        var upload = fake.Requests[0];
        Assert.Equal("application/octet-stream", upload.Headers["Content-Type"]);
        Assert.Equal("true", upload.Headers["x-upsert"]);
        Assert.Equal($"Bearer {fake.AccessToken}", upload.Headers["Authorization"]);
        Assert.Equal(-1, upload.Body.AsSpan().IndexOf("secret"u8));
        Assert.Equal(png, SyncVault.Open(upload.Body, key));
        var row = fake.Requests[1].Json!.AsArray().Single()!.AsObject();
        Assert.Equal(["id", "type", "created_at"], row.Select(column => column.Key));
        Assert.Equal("image/png", (string?)row["type"]);
        Assert.DoesNotContain(NoteStore.DirtyImages(int.MaxValue), i => i.Id == mine);

        // Another device's: its row, then its sealed bytes from Storage, opened.
        var theirs = NewID();
        byte[] jpeg = [0xFF, 0xD8, .. "holiday photo"u8];
        fake.PutFile($"{fake.UserID}/{theirs}", SyncVault.Seal(jpeg, key));
        fake.Put("images", new JsonObject { ["id"] = theirs, ["type"] = "image/jpeg", ["created_at"] = 5.0 });
        fake.ClearRequests();
        await sync.Sync(pull: true);
        Assert.Null(sync.Error);
        Assert.Contains(fake.Requests, r => r.ToString() == $"GET /storage/v1/object/authenticated/images/{fake.UserID}/{theirs}");
        Assert.Equal(jpeg, NoteStore.Image(theirs)?.Data);
        Assert.Equal("image/jpeg", NoteStore.Image(theirs)?.Type);
        Assert.DoesNotContain(NoteStore.DirtyImages(int.MaxValue), i => i.Id == theirs);  // not sent back

        // An image that won't come doesn't hold up notes: they sync, and the error says what happened.
        fake.Put("images", new JsonObject { ["id"] = NewID(), ["type"] = "image/png", ["created_at"] = 6.0 });
        var note = new Note { Kind = NoteKind.Url, Target = "", Label = "", Text = "synced despite the image" };
        NoteStore.Save(note);
        await sync.Sync(pull: true);
        Assert.Equal("Images didn't sync: Object not found", sync.Error);
        Assert.True(fake.Has("notes", note.Id));
        Assert.NotNull(sync.LastSynced);
    }

    [Fact]
    public async Task RoundsDontOverlap()
    {
        var fake = new FakeSupabase();
        var sync = await Device(fake);
        int Pulls() => fake.Requests.Count(r => r.Method == "GET" && r.Path == "/rest/v1/notes");
        foreach (var (asked, pulls) in new[] { (new[] { false, false }, 1), (new[] { false, true, false }, 2) })
        {
            fake.ClearRequests();
            var hold = new TaskCompletionSource();
            fake.Hold = () => hold.Task;
            var running = sync.Sync(pull: true);
            await Eventually(() => fake.Requests.Count > 0);
            Assert.True(sync.Busy);
            // Asked for meanwhile: one more round once this one is done, a pull if any of them wanted one.
            Assert.All(asked, pull => Assert.Same(running, sync.Sync(pull)));
            hold.SetResult();
            await running;
            Assert.Null(sync.Error);
            Assert.False(sync.Busy);
            Assert.Equal(pulls, Pulls());
        }
    }

    [Fact]
    public async Task SigningOutForgetsTheAccountNotTheNotes()
    {
        var fake = new FakeSupabase();
        var secrets = new MemorySecretStore();
        var sync = await Device(fake, secrets);
        var note = new Note { Kind = NoteKind.Url, Target = "", Label = "", Text = "kept on this PC" };
        NoteStore.Save(note);
        sync.SignOut();
        Assert.Null(sync.Email);
        Assert.Null(sync.Vault);
        Assert.Null(sync.LastSynced);
        Assert.False(sync.Active);
        Assert.Null(secrets.Get("session"));
        Assert.Null(SyncVault.SavedKey(secrets, fake.UserID));
        Assert.Contains(NoteStore.LoadAll(), n => n.Id == note.Id);
        await sync.Sync(pull: true);
        Assert.Empty(fake.Requests);
    }

    /// At launch, as the Mac: a round at once, a push shortly after any save, a pull when Realtime reports a change.
    [Fact]
    public async Task OnceStartedItSyncsAfterSavesAndOnRealtimeNews()
    {
        using var server = new LoopbackSocket();
        var fake = new FakeSupabase();
        var sync = await Device(fake);
        var before = sync.LastSynced;
        sync.Start(server.Url, every: TimeSpan.FromHours(1), afterSave: TimeSpan.FromMilliseconds(100));
        try
        {
            using var socket = (await server.Accept())!;
            var join = await LoopbackSocket.Receive(socket);
            Assert.Equal("phx_join", (string?)join["event"]);
            Assert.Equal(fake.AccessToken, (string?)join["payload"]!["access_token"]);
            await Eventually(() => sync.LastSynced > before);

            var note = new Note { Kind = NoteKind.Url, Target = "", Label = "", Text = "saved while syncing" };
            NoteStore.Save(note);
            await Eventually(() => fake.Has("notes", note.Id));

            const string change = """{"event":"postgres_changes","payload":{"data":{"table":"notes","type":"UPDATE"}},"ref":null,"topic":"realtime:memorynotes"}""";
            fake.ClearRequests();
            await LoopbackSocket.Send(socket, change);
            await Eventually(() => fake.Requests.Any(r => r.Method == "GET" && r.Path == "/rest/v1/notes"));

            // A round that fails after writing what it pulled: the error stays up, though those writes wake the watcher.
            fake.Put("notes", NoteRow(NewID(), "from the Mac", VaultKey(fake), at: 10));
            fake.Put("images", new JsonObject { ["id"] = NewID(), ["type"] = "image/png", ["created_at"] = 6.0 });
            await LoopbackSocket.Send(socket, change);
            await Eventually(() => sync.Error == "Images didn't sync: Object not found");
            await Task.Delay(1500);
            Assert.Equal("Images didn't sync: Object not found", sync.Error);
        }
        finally
        {
            sync.SignOut();
            await sync.Running;
        }
    }
}
