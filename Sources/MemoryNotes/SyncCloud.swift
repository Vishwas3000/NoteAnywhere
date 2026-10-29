import CryptoKit
import Foundation
import notify
import Security

/// Optional sync through Supabase (D31). Each device keeps its own SQLite database: rows edited here are pushed,
/// rows other devices pushed are pulled by `seq`, and the server keeps the newer edit. Off until the user turns it on.
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    static let projectURL = URL(string: "https://strhaqnvxtpmlvcwkkne.supabase.co")!
    /// Publishable (anon) key: meant to ship in apps; row level security keeps each account's notes to itself.
    static let publishableKey = "sb_publishable_9GowTlVr_z6p3W1d2W-28g_M0Ke1Mzv"

    enum Mode: String, CaseIterable { case off, cloud, icloud }

    @Published var mode: Mode { didSet { modeChanged() } }
    @Published private(set) var email: String?  // signed in as
    @Published private(set) var pendingEmail: String?  // a code was sent here
    @Published private(set) var lastSynced: Date?
    @Published private(set) var busy = false
    @Published var error: String?
    /// End-to-end encryption step after signing in: nil until known, then create/enter a passphrase, or ready.
    @Published private(set) var vault: VaultStep?
    enum VaultStep { case create, enter, ready }
    private var vaultKey: SymmetricKey?

    private var session: Session? { didSet { email = session?.email } }
    private var timer: Timer?
    private var notifyToken: Int32 = 0
    private var pushSoon: Task<Void, Never>?
    private var running = false
    private var rerun: Bool?  // nil: none; false: push only; true: push and pull
    private let realtime = Realtime()

    private init() {
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: "syncMode") ?? "") ?? .off
        session = Keychain.load()
        email = session?.email
        vaultKey = session.flatMap { Keychain.vaultKey(for: $0.userID) }
        vault = vaultKey != nil ? .ready : nil
        realtime.onChange = { [weak self] in self?.syncNow() }
        modeChanged()
    }

    /// Syncing needs an account and the vault key: nothing goes up unencrypted.
    var active: Bool { mode == .cloud && session != nil && vaultKey != nil }

    private func modeChanged() {
        UserDefaults.standard.set(mode.rawValue, forKey: "syncMode")
        stop()
        if mode == .cloud, session != nil, vaultKey == nil { Task { await checkVault() } }
        guard active else { return }
        // Local saves (this app, the browser host, the share extension) post this; push them shortly after.
        notify_register_dispatch(NoteStore.changed, &notifyToken, .main) { [weak self] _ in
            self?.pushSoon?.cancel()
            self?.pushSoon = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { self?.sync(pull: false) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
        Task { if let token = try? await accessToken() { realtime.connect(token: token) } }
        syncNow()
    }

    private func stop() {
        if notifyToken != 0 { notify_cancel(notifyToken); notifyToken = 0 }
        timer?.invalidate()
        timer = nil
        pushSoon?.cancel()
        realtime.disconnect()
    }

    // MARK: Sign in by email: a link that opens the app, or the code if the email carries one

    /// Where sign-in links land; allowed in supabase/config.toml and registered as the apps' URL scheme.
    static let callback = "memorynotes://auth-callback"

    /// Google sign-in through Supabase: it redirects back to `callback` with the session, like the email link.
    static let googleURL = URL(string: "auth/v1/authorize?provider=google&redirect_to="
                                   + callback.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!, relativeTo: projectURL)!

    func sendLink(to email: String) async {
        let email = email.trimmingCharacters(in: .whitespaces).lowercased()
        await perform {
            _ = try await self.auth("otp", ["email": email, "create_user": true],
                                    query: "redirect_to=" + Self.callback.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
            self.pendingEmail = email
        }
    }

    func verify(code: String) async {
        guard let email = pendingEmail else { return }
        await perform {
            try self.signedIn(try await self.auth("verify", ["type": "email", "email": email, "token": code.filter(\.isNumber)]))
        }
    }

    /// The sign-in link's redirect: memorynotes://auth-callback#access_token=…&refresh_token=…&expires_at=…
    func handle(_ url: URL) async {
        guard url.absoluteString.hasPrefix(Self.callback) else { return }
        var fields: [String: String] = [:]
        for part in [url.fragment, URLComponents(url: url, resolvingAgainstBaseURL: false)?.query].compactMap({ $0 }) {
            for item in URLComponents(string: "?" + part)?.queryItems ?? [] { fields[item.name] = item.value }
        }
        await perform {
            if let problem = fields["error_description"] { throw Failure(errorDescription: problem.replacingOccurrences(of: "+", with: " ")) }
            guard let access = fields["access_token"], let refresh = fields["refresh_token"] else {
                throw Failure(errorDescription: "That sign-in link didn't work. Send a new one.")
            }
            var request = URLRequest(url: URL(string: "auth/v1/user", relativeTo: Self.projectURL)!)
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            let user = (try JSONSerialization.jsonObject(with: try await self.send(request))) as? [String: Any] ?? [:]
            try self.signedIn(["access_token": access, "refresh_token": refresh, "user": user,
                               "expires_at": Double(fields["expires_at"] ?? "") as Any,
                               "expires_in": Double(fields["expires_in"] ?? "") as Any])
        }
    }

    private func signedIn(_ reply: [String: Any]) throws {
        let session = try Session(reply)
        if NoteStore.syncValue("user") != session.userID {
            try NoteStore.resetSync()  // another account: send it everything, fetch all of its notes
            try NoteStore.setSyncValue("user", session.userID)
        }
        Keychain.save(session)
        self.session = session
        pendingEmail = nil
        vaultKey = Keychain.vaultKey(for: session.userID)
        vault = vaultKey != nil ? .ready : nil
        modeChanged()
    }

    func cancelCode() { pendingEmail = nil }

    /// Stops syncing and forgets the account on this device; notes stay here.
    func signOut() {
        stop()
        if let id = session?.userID { Keychain.deleteVaultKey(for: id) }
        Keychain.delete()
        session = nil
        vaultKey = nil
        vault = nil
        lastSynced = nil
    }

    // MARK: End-to-end encryption

    /// Is there a vault for this account yet (another device made it), or is this the first device?
    private func checkVault() async {
        await perform {
            let rows = try JSONSerialization.jsonObject(with: try await self.rest("vaults?select=salt,wrapped", method: "GET")) as? [Any]
            self.vault = (rows ?? []).isEmpty ? .create : .enter
        }
    }

    /// First device: a random vault key, stored on the server only wrapped by the passphrase.
    func createVault(passphrase: String) async {
        await perform {
            let key = SymmetricKey(size: .bits256)
            let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            let wrapped = try AES.GCM.seal(key.withUnsafeBytes { Data($0) }, using: NoteLock.key(passphrase, salt)).combined!
            // A plain insert: if another device just made the vault, this fails rather than replacing its key.
            do {
                try await self.rest("vaults", method: "POST", body: [["salt": salt.base64EncodedString(), "wrapped": wrapped.base64EncodedString()]],
                                    upsert: false)
            } catch {
                self.vault = .enter
                throw Failure(errorDescription: "Another device already set a sync passphrase. Enter that one.")
            }
            self.unlocked(key)
        }
    }

    /// Any other device: unwrap the vault key with the passphrase.
    func enterVault(passphrase: String) async {
        await perform {
            let data = try await self.rest("vaults?select=salt,wrapped", method: "GET")
            guard let row = (try JSONSerialization.jsonObject(with: data) as? [[String: String]])?.first,
                  let salt = row["salt"].flatMap({ Data(base64Encoded: $0) }),
                  let wrapped = row["wrapped"].flatMap({ Data(base64Encoded: $0) }) else { throw Failure(errorDescription: "No vault yet.") }
            guard let raw = try? AES.GCM.open(AES.GCM.SealedBox(combined: wrapped), using: NoteLock.key(passphrase, salt)) else {
                throw Failure(errorDescription: "That passphrase doesn't open your synced notes.")
            }
            self.unlocked(SymmetricKey(data: raw))
        }
    }

    private func unlocked(_ key: SymmetricKey) {
        guard let id = session?.userID else { return }
        Keychain.saveVaultKey(key, for: id)
        vaultKey = key
        vault = .ready
        modeChanged()
    }

    // MARK: Sync

    func syncNow() { sync(pull: true) }

    private func sync(pull: Bool) {
        guard active else { return }
        if running { rerun = (rerun ?? false) || pull; return }
        running = true
        Task {
            await perform(showBusy: pull) {
                // Images go up before the notes that show them, but a failing image (say the server isn't set up for
                // them yet) mustn't hold up notes: it's reported after they're through.
                var imageError: Error?
                do { try await self.pushImages() } catch { imageError = error }
                try await self.push()
                if pull {
                    try await self.pull()
                    do { try await self.pullImages() } catch { imageError = imageError ?? error }
                }
                self.lastSynced = Date()
                if let imageError { throw Failure(errorDescription: "Images didn't sync: \(imageError.localizedDescription)") }
            }
            running = false
            if let again = rerun { rerun = nil; sync(pull: again) }
        }
    }

    private func push() async throws {
        guard let key = vaultKey else { return }
        let folders = NoteStore.dirtyFolders()  // first: notes point at them
        if !folders.isEmpty {
            try await rest("folders?on_conflict=id", method: "POST", body: try folders.map { try $0.row(sealing: key) })
            try NoteStore.markPushed(folders: folders)
        }
        while true {
            let notes = NoteStore.dirtyNotes()
            if !notes.isEmpty {
                try await rest("notes?on_conflict=id", method: "POST", body: try notes.map { try $0.row(sealing: key) })
                try NoteStore.markPushed(notes: notes)
            }
            // Snapshots reference notes, so they go up after them.
            let snapshots = NoteStore.dirtySnapshots()
            if !snapshots.isEmpty {
                try await rest("snapshots?on_conflict=note_id,day", method: "POST", body: try snapshots.map { try $0.row(sealing: key) })
                try NoteStore.markPushed(snapshots: snapshots)
            }
            if notes.count < 200 && snapshots.count < 500 { return }
        }
    }

    // shortcut: a row committed out of seq order by a concurrent writer could be skipped until it changes again;
    // fine for one person's devices, switch to a server-side "changes since" function if that ever matters.
    private func page<Row: Decodable>(_ table: String, _ columns: String, _ type: Row.Type) async throws -> [Row] {
        let cursor = NoteStore.syncValue("cursor.\(table)") ?? "0"
        let data = try await rest("\(table)?select=\(columns),seq&seq=gt.\(cursor)&order=seq.asc&limit=500", method: "GET")
        return try JSONDecoder().decode([Row].self, from: data)
    }

    private func pull() async throws {
        guard let key = vaultKey else { return }
        while true {
            let folders = try await page("folders", "id,name,updated_at,deleted_at", NoteStore.CloudFolder.self)
            let notes = try await page("notes", "id,kind,target,label,body_md,created_at,updated_at,deleted_at,pinned,folder_id,color,locked",
                                       NoteStore.CloudNote.self)
            let snapshots = try await page("snapshots", "note_id,day,body_md,updated_at", NoteStore.CloudSnapshot.self)
            try NoteStore.applyRemote(notes: try notes.map { try $0.opened(with: key) },
                                      snapshots: try snapshots.map { try $0.opened(with: key) },
                                      folders: try folders.map { try $0.opened(with: key) })
            if let last = folders.last?.seq { try NoteStore.setSyncValue("cursor.folders", String(last)) }
            if let last = notes.last?.seq { try NoteStore.setSyncValue("cursor.notes", String(last)) }
            if let last = snapshots.last?.seq { try NoteStore.setSyncValue("cursor.snapshots", String(last)) }
            if notes.count < 500 && snapshots.count < 500 && folders.count < 500 { return }
        }
    }

    /// Image bytes, sealed with the vault key, go to Storage under the account's folder; then the row says they're there.
    private func pushImages() async throws {
        guard let key = vaultKey, let user = session?.userID else { return }
        while true {
            let images = NoteStore.dirtyImages()
            for image in images {
                guard let bytes = NoteStore.image(image.id)?.data else {
                    throw Failure(errorDescription: "Image \(image.id) is missing from this device.")
                }
                try await storage("\(user)/\(image.id)", upload: try SyncVault.seal(bytes, key))
            }
            if !images.isEmpty {
                try await rest("images?on_conflict=id", method: "POST",
                               body: images.map { ["id": $0.id, "type": $0.type, "created_at": $0.created_at] })
                try NoteStore.markPushed(images: images)
            }
            if images.count < 50 { return }
        }
    }

    /// New image rows from other devices; each one's bytes are downloaded and written before the cursor moves past it.
    private func pullImages() async throws {
        guard let key = vaultKey, let user = session?.userID else { return }
        while true {
            let images = try await page("images", "id,type,created_at", NoteStore.CloudImage.self)
            for image in images where NoteStore.wantsImage(image) {
                try NoteStore.saveRemoteImage(image, data: try SyncVault.open(try await storage("\(user)/\(image.id)"), key))
            }
            if let last = images.last?.seq { try NoteStore.setSyncValue("cursor.images", String(last)) }
            if images.count < 500 { return }
        }
    }

    private func perform(showBusy: Bool = true, _ work: @escaping () async throws -> Void) async {
        if showBusy { busy = true }
        defer { if showBusy { busy = false } }
        do {
            try await work()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: HTTP

    struct Failure: LocalizedError { let errorDescription: String? }

    private func auth(_ path: String, _ body: [String: Any], query: String = "") async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "auth/v1/\(path)" + (query.isEmpty ? "" : "?" + query), relativeTo: Self.projectURL)!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @discardableResult
    private func rest(_ path: String, method: String, body: [[String: Any]]? = nil, upsert: Bool = true) async throws -> Data {
        var request = URLRequest(url: URL(string: "rest/v1/\(path)", relativeTo: Self.projectURL)!)
        request.httpMethod = method
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue(upsert ? "resolution=merge-duplicates,return=minimal" : "return=minimal", forHTTPHeaderField: "Prefer")
        }
        return try await send(request)
    }

    /// One image's sealed bytes in the private "images" bucket: uploads (replacing) with `upload`, downloads without.
    @discardableResult
    private func storage(_ path: String, upload: Data? = nil) async throws -> Data {
        let route = upload == nil ? "storage/v1/object/authenticated/images/" : "storage/v1/object/images/"
        var request = URLRequest(url: URL(string: route + path, relativeTo: Self.projectURL)!)
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        if let upload {
            request.httpMethod = "POST"
            request.httpBody = upload
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue("true", forHTTPHeaderField: "x-upsert")
        }
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        if request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = ["msg", "message", "error_description", "error"].lazy.compactMap { json?[$0] as? String }.first
            if status == 401 || status == 403, message?.contains("JWT") == true { session = nil; Keychain.delete() }
            throw Failure(errorDescription: message ?? "The sync server answered \(status).")
        }
        return data
    }

    /// A valid access token, refreshed a minute before it expires.
    private func accessToken() async throws -> String {
        guard var session else { throw Failure(errorDescription: "Sign in to sync.") }
        if session.expiresAt - 60 < Date().timeIntervalSince1970 {
            session = try Session(try await auth("token", ["refresh_token": session.refreshToken],
                                                 query: "grant_type=refresh_token"))
            Keychain.save(session)
            self.session = session
            realtime.update(token: session.accessToken)
        }
        return session.accessToken
    }
}

/// What the server sees of a note: ids, times, kind, pin/colour/folder ids and the locked flag. The text, the place
/// (page address or app/chat path), the title and folder names are AES-GCM sealed with the vault key.
enum SyncVault {
    static let prefix = "mne2e:v1:"

    static func seal(_ text: String, _ key: SymmetricKey) throws -> String {
        prefix + (try AES.GCM.seal(Data(text.utf8), using: key).combined!).base64EncodedString()
    }

    static func open(_ text: String, _ key: SymmetricKey) throws -> String {
        guard text.hasPrefix(prefix), let data = Data(base64Encoded: String(text.dropFirst(prefix.count))),
              let plain = try? AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key) else {
            throw CloudSync.Failure(errorDescription: "A synced note can't be read with this passphrase.")
        }
        return String(decoding: plain, as: UTF8.self)
    }

    /// Image bytes: AES-GCM's combined form (nonce, ciphertext, tag), with no prefix since there's no plain legacy to tell apart.
    static func seal(_ data: Data, _ key: SymmetricKey) throws -> Data { try AES.GCM.seal(data, using: key).combined! }

    static func open(_ data: Data, _ key: SymmetricKey) throws -> Data {
        guard let plain = try? AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key) else {
            throw CloudSync.Failure(errorDescription: "A synced image can't be read with this passphrase.")
        }
        return plain
    }
}

extension NoteStore.CloudNote {
    /// Every column on every row: PostgREST takes a batch's columns from its first object, so nulls must be explicit.
    func row(sealing key: SymmetricKey) throws -> [String: Any] {
        ["id": id, "kind": kind, "target": try SyncVault.seal(target, key), "label": try SyncVault.seal(label, key),
         "body_md": try SyncVault.seal(body_md, key),
         "created_at": created_at, "updated_at": updated_at, "deleted_at": deleted_at ?? NSNull(),
         "pinned": pinned ?? false, "folder_id": folder_id ?? NSNull(), "color": color ?? NSNull(), "locked": locked ?? false]
    }

    func opened(with key: SymmetricKey) throws -> Self {
        var n = self
        n.target = try SyncVault.open(target, key)
        n.label = try SyncVault.open(label, key)
        n.body_md = try SyncVault.open(body_md, key)
        return n
    }
}

extension NoteStore.CloudFolder {
    func row(sealing key: SymmetricKey) throws -> [String: Any] {
        ["id": id, "name": try SyncVault.seal(name, key), "updated_at": updated_at, "deleted_at": deleted_at ?? NSNull()]
    }

    func opened(with key: SymmetricKey) throws -> Self {
        var f = self
        f.name = try SyncVault.open(name, key)
        return f
    }
}

extension NoteStore.CloudSnapshot {
    func row(sealing key: SymmetricKey) throws -> [String: Any] {
        ["note_id": note_id, "day": day, "body_md": try SyncVault.seal(body_md, key), "updated_at": updated_at]
    }

    func opened(with key: SymmetricKey) throws -> Self {
        var s = self
        s.body_md = try SyncVault.open(body_md, key)
        return s
    }
}

private struct Session: Codable {
    var accessToken: String, refreshToken: String, expiresAt: Double, userID: String, email: String

    init(_ reply: [String: Any]) throws {
        guard let access = reply["access_token"] as? String, let refresh = reply["refresh_token"] as? String,
              let user = reply["user"] as? [String: Any], let id = user["id"] as? String else {
            throw CloudSync.Failure(errorDescription: "That code didn't work. Check it, or send a new one.")
        }
        accessToken = access
        refreshToken = refresh
        expiresAt = (reply["expires_at"] as? Double) ?? Date().timeIntervalSince1970 + ((reply["expires_in"] as? Double) ?? 3600)
        userID = id
        email = user["email"] as? String ?? ""
    }
}

/// The session lives in the Keychain, never in the notes database or defaults.
private enum Keychain {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: "com.memorynotes.sync", kSecAttrAccount as String: "session"]

    static func load() -> Session? {
        var item: CFTypeRef?
        guard SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func save(_ session: Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query.merging([kSecValueData as String: data,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]) { $1 } as CFDictionary, nil)
    }

    static func delete() { SecItemDelete(query as CFDictionary) }

    /// The vault key for one account, on this device only.
    private static func vaultQuery(_ userID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.memorynotes.sync",
         kSecAttrAccount as String: "vault-\(userID)"]
    }

    static func vaultKey(for userID: String) -> SymmetricKey? {
        var item: CFTypeRef?
        guard SecItemCopyMatching(vaultQuery(userID).merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    static func saveVaultKey(_ key: SymmetricKey, for userID: String) {
        SecItemDelete(vaultQuery(userID) as CFDictionary)
        SecItemAdd(vaultQuery(userID).merging([kSecValueData as String: key.withUnsafeBytes { Data($0) },
                                               kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 }
                   as CFDictionary, nil)
    }

    static func deleteVaultKey(for userID: String) { SecItemDelete(vaultQuery(userID) as CFDictionary) }
}

/// Supabase Realtime over a plain WebSocket (Phoenix protocol): any change to this account's notes triggers a pull.
@MainActor
private final class Realtime: NSObject {
    var onChange: () -> Void = {}
    private var socket: URLSessionWebSocketTask?
    private var heartbeat: Timer?
    private var token: String?
    private var ref = 0
    private let topic = "realtime:memorynotes"

    func connect(token: String) {
        disconnect()
        self.token = token
        var url = URLComponents(url: CloudSync.projectURL.appendingPathComponent("realtime/v1/websocket"), resolvingAgainstBaseURL: false)!
        url.scheme = "wss"
        url.queryItems = [.init(name: "apikey", value: CloudSync.publishableKey), .init(name: "vsn", value: "1.0.0")]
        let socket = URLSession.shared.webSocketTask(with: url.url!)
        self.socket = socket
        socket.resume()
        send(topic, "phx_join", ["config": ["postgres_changes": [["event": "*", "schema": "public", "table": "notes"],
                                                                 ["event": "*", "schema": "public", "table": "folders"]]],
                                 "access_token": token])
        heartbeat = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.send("phoenix", "heartbeat", [:]) }
        }
        receive(socket)
    }

    func update(token: String) {
        self.token = token
        send(topic, "access_token", ["access_token": token])
    }

    func disconnect() {
        heartbeat?.invalidate()
        heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func send(_ topic: String, _ event: String, _ payload: [String: Any]) {
        ref += 1
        let message: [String: Any] = ["topic": topic, "event": event, "payload": payload, "ref": String(ref)]
        guard let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }

    private func receive(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, socket === self.socket else { return }
                switch result {
                case .success(.string(let text)):
                    if text.contains("\"postgres_changes\"") { self.onChange() }
                    self.receive(socket)
                case .success:
                    self.receive(socket)
                case .failure:
                    // Dropped (sleep, network change): reconnect after a pause; the 60 s timer covers the gap.
                    try? await Task.sleep(for: .seconds(10))
                    if socket === self.socket, let token = self.token { self.connect(token: token) }
                }
            }
        }
    }
}
