using NoteAnywhere.Core.Crypto;
using static NoteAnywhere.Core.NoteStore;

namespace NoteAnywhere.Core.Sync;

/// What the server sees of a note: ids, times, kind, pin/star/colour/folder ids and the locked flag. The text, the place
/// (page address or app/chat path), the title, a snapshot's text and a folder's name are sealed with the vault key.
static class CloudRows
{
    /// Every column on every row: PostgREST takes a batch's columns from its first object, so nulls must be explicit.
    public static Dictionary<string, object?> Row(this CloudNote n, byte[] key) => new()
    {
        ["id"] = n.Id, ["kind"] = n.Kind, ["target"] = SyncVault.Seal(n.Target, key), ["label"] = SyncVault.Seal(n.Label, key),
        ["body_md"] = SyncVault.Seal(n.BodyMd, key), ["created_at"] = n.CreatedAt, ["updated_at"] = n.UpdatedAt,
        ["deleted_at"] = n.DeletedAt, ["pinned"] = n.Pinned ?? false, ["folder_id"] = n.FolderID, ["color"] = n.Color,
        ["locked"] = n.Locked ?? false, ["starred"] = n.Starred ?? false,
    };

    public static CloudNote Opened(this CloudNote n, byte[] key) =>
        n with { Target = SyncVault.Open(n.Target, key), Label = SyncVault.Open(n.Label, key), BodyMd = SyncVault.Open(n.BodyMd, key) };

    public static Dictionary<string, object?> Row(this CloudFolder f, byte[] key) => new()
    {
        ["id"] = f.Id, ["name"] = SyncVault.Seal(f.Name, key), ["updated_at"] = f.UpdatedAt, ["deleted_at"] = f.DeletedAt,
    };

    public static CloudFolder Opened(this CloudFolder f, byte[] key) => f with { Name = SyncVault.Open(f.Name, key) };

    public static Dictionary<string, object?> Row(this CloudSnapshot s, byte[] key) => new()
    {
        ["note_id"] = s.NoteID, ["day"] = s.Day, ["body_md"] = SyncVault.Seal(s.BodyMd, key), ["updated_at"] = s.UpdatedAt,
    };

    public static CloudSnapshot Opened(this CloudSnapshot s, byte[] key) => s with { BodyMd = SyncVault.Open(s.BodyMd, key) };

    public static Dictionary<string, object?> Row(this CloudImage i) => new()
    {
        ["id"] = i.Id, ["type"] = i.Type, ["created_at"] = i.CreatedAt,
    };
}
