import CryptoKit
import Testing
@testable import MemoryNotes

@Test func syncedRowsCarryNoReadableText() throws {
    let key = SymmetricKey(size: .bits256)
    let note = NoteStore.CloudNote(id: "a", kind: "app", target: "com.tinyspeck.slackmacgap/Acme/Alex Rivera (DM)", label: "Slack",
                                   body_md: "secret plan", created_at: 1, updated_at: 2, deleted_at: nil)
    let row = try note.row(sealing: key)
    for field in ["target", "label", "body_md"] {
        let value = try #require(row[field] as? String)
        #expect(value.hasPrefix(SyncVault.prefix) && !value.contains("secret") && !value.contains("Alex"))
    }
    var back = note
    back.target = row["target"] as! String
    back.label = row["label"] as! String
    back.body_md = row["body_md"] as! String
    #expect(try back.opened(with: key) == note)
    #expect(throws: CloudSync.Failure.self) { try back.opened(with: SymmetricKey(size: .bits256)) }
}
