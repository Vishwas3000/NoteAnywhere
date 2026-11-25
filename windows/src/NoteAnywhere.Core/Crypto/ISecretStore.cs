namespace NoteAnywhere.Core.Crypto;

/// Secrets kept on this device only, where the Mac uses its Keychain: the notes password, each account's vault key
/// and the sync session.
public interface ISecretStore
{
    byte[]? Get(string name);
    void Set(string name, byte[] value);
    void Delete(string name);
}
