import Testing
@testable import MemoryNotes

@Test func lockedTextOpensOnlyWithItsPassword() throws {
    let sealed = try NoteLock.seal("bank pin 1234", password: "hunter2")
    #expect(NoteLock.isEnvelope(sealed) && !sealed.contains("1234"))
    #expect(try NoteLock.open(sealed, password: "hunter2") == "bank pin 1234")
    #expect(throws: NoteLock.Failure.self) { try NoteLock.open(sealed, password: "wrong") }
    // Re-sealing while typing keeps the note's salt (one key derivation per note), with a fresh nonce.
    let again = try NoteLock.seal("bank pin 12345", password: "hunter2", reusing: sealed)
    #expect(again.dropFirst(NoteLock.prefix.count).prefix(20) == sealed.dropFirst(NoteLock.prefix.count).prefix(20))
    #expect(again != sealed)
    #expect(throws: NoteLock.Failure.self) { try NoteLock.open(NoteLock.prefix + "garbage", password: "hunter2") }
}
