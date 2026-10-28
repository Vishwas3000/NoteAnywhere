import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Locked notes, like Apple Notes': one notes password; each locked note's text is an AES-GCM envelope
/// "mnlock:v1:<base64 salt|nonce|ciphertext|tag>" keyed by PBKDF2-SHA256(password, salt). The database, sync, search
/// and the browser only ever see the envelope. A forgotten password can't be recovered.
enum NoteLock {
    static let prefix = "mnlock:v1:"
    static let iterations: UInt32 = 310_000  // OWASP's PBKDF2-SHA256 floor; ~0.2 s per new salt, cached after
    struct Failure: LocalizedError { let errorDescription: String? }

    static func isEnvelope(_ text: String) -> Bool { text.hasPrefix(prefix) }

    /// Encrypts with a fresh salt, or `reusing` an existing envelope's salt so re-saving while typing stays fast.
    static func seal(_ plaintext: String, password: String, reusing envelope: String? = nil) throws -> String {
        let salt = envelope.flatMap { try? parts($0).salt } ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: key(password, salt))
        guard let combined = box.combined else { throw Failure(errorDescription: "Couldn't encrypt the note.") }
        return prefix + (salt + combined).base64EncodedString()
    }

    static func open(_ envelope: String, password: String) throws -> String {
        let (salt, combined) = try parts(envelope)
        do {
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key(password, salt))
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw Failure(errorDescription: "That password doesn't open this note.")
        }
    }

    private static func parts(_ envelope: String) throws -> (salt: Data, combined: Data) {
        guard envelope.hasPrefix(prefix), let data = Data(base64Encoded: String(envelope.dropFirst(prefix.count))),
              data.count > 16 + 12 + 16 else { throw Failure(errorDescription: "This locked note is damaged.") }
        return (data.prefix(16), data.dropFirst(16))
    }

    private static let keys = NSCache<NSString, NSData>()  // derived keys by password+salt, for this run only

    private static func key(_ password: String, _ salt: Data) -> SymmetricKey {
        let id = "\(password.hashValue)/\(salt.base64EncodedString())" as NSString
        if let cached = keys.object(forKey: id) { return SymmetricKey(data: cached as Data) }
        var derived = Data(count: 32)
        let pass = Array(password.utf8)
        _ = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.map { Int8(bitPattern: $0) }, pass.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     out.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        keys.setObject(derived as NSData, forKey: id)
        return SymmetricKey(data: derived)
    }
}

/// Whether locked notes are open right now. Unlocking checks the password against a stored check value; it stays
/// unlocked until "Lock Now", the screen locks or the app quits.
@MainActor
final class LockSession: ObservableObject {
    static let shared = LockSession()

    @Published private(set) var password: String?
    var isUnlocked: Bool { password != nil }
    /// A password exists once the first note was locked (its check value lives in the notes database).
    var hasPassword: Bool { NoteStore.syncValue("lock.check") != nil }
    var hint: String? { NoteStore.syncValue("lock.hint") }
    var canUseBiometrics: Bool { hasPassword && Keychain.password() != nil }

    private static let check = "noteanywhere-lock-check"

    private init() {
        #if os(macOS)
        // Lock again when the screen locks or the Mac sleeps, like Apple Notes.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in LockSession.shared.lockNow() }
        }
        #endif
    }

    /// First lock: choose the notes password. Touch ID can then unlock it on this device.
    func setPassword(_ password: String, hint: String) throws {
        try NoteStore.setSyncValue("lock.check", try NoteLock.seal(Self.check, password: password))
        try NoteStore.setSyncValue("lock.hint", hint.isEmpty ? nil : hint)
        Keychain.save(password)
        self.password = password
    }

    func unlock(with password: String) throws {
        let wrong = NoteLock.Failure(errorDescription: "Wrong password.")
        if let check = NoteStore.syncValue("lock.check") {
            guard (try? NoteLock.open(check, password: password)) == Self.check else { throw wrong }
        } else if let envelope = NotesModel.shared.notes.first(where: \.locked)?.text {
            // Notes locked on another device: the first one that opens proves the password; remember it here.
            guard (try? NoteLock.open(envelope, password: password)) != nil else { throw wrong }
            try? NoteStore.setSyncValue("lock.check", try NoteLock.seal(Self.check, password: password))
        } else {
            throw NoteLock.Failure(errorDescription: "No note is locked yet.")
        }
        Keychain.save(password)
        self.password = password
    }

    /// Touch ID (or the Mac's password), then the notes password from this app's Keychain item.
    func unlockWithBiometrics() async throws {
        let context = LAContext()
        let reason = "unlock your locked notes"
        _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        guard let saved = Keychain.password() else { throw NoteLock.Failure(errorDescription: "Enter the notes password once on this device.") }
        try unlock(with: saved)
    }

    func lockNow() { password = nil }

    private enum Keychain {
        static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                           kSecAttrService as String: "com.memorynotes.lock", kSecAttrAccount as String: "notes-password"]

        static func password() -> String? {
            var item: CFTypeRef?
            guard SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func save(_ password: String) {
            SecItemDelete(query as CFDictionary)
            SecItemAdd(query.merging([kSecValueData as String: Data(password.utf8),
                                      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { $1 } as CFDictionary, nil)
        }
    }
}
