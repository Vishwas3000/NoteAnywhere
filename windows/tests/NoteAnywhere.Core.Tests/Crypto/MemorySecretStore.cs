using NoteAnywhere.Core.Crypto;

namespace NoteAnywhere.Core.Tests.Crypto;

sealed class MemorySecretStore : ISecretStore
{
    readonly Dictionary<string, byte[]> items = [];

    public byte[]? Get(string name) => items.GetValueOrDefault(name);
    public void Set(string name, byte[] value) => items[name] = value;
    public void Delete(string name) => items.Remove(name);
}
