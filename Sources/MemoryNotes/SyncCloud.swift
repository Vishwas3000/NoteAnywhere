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
        realtime.onChange = { [weak self] in self?.syncNow() }
        modeChanged()
    }

    var active: Bool { mode == .cloud && session != nil }

    private func modeChanged() {
        UserDefaults.standard.set(mode.rawValue, forKey: "syncMode")
        stop()
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
        modeChanged()
    }

    func cancelCode() { pendingEmail = nil }

    /// Stops syncing and forgets the account on this device; notes stay here.
    func signOut() {
        stop()
        Keychain.delete()
        session = nil
        lastSynced = nil
    }

    // MARK: Sync

    func syncNow() { sync(pull: true) }

    private func sync(pull: Bool) {
        guard active else { return }
        if running { rerun = (rerun ?? false) || pull; return }
        running = true
        Task {
            await perform(showBusy: pull) {
                try await self.push()
                if pull { try await self.pull() }
                self.lastSynced = Date()
            }
            running = false
            if let again = rerun { rerun = nil; sync(pull: again) }
        }
    }

    private func push() async throws {
        while true {
            let notes = NoteStore.dirtyNotes()
            if !notes.isEmpty {
                try await rest("notes?on_conflict=id", method: "POST", body: notes.map(\.row))
                try NoteStore.markPushed(notes: notes)
            }
            // Snapshots reference notes, so they go up after them.
            let snapshots = NoteStore.dirtySnapshots()
            if !snapshots.isEmpty {
                try await rest("snapshots?on_conflict=note_id,day", method: "POST", body: snapshots.map(\.row))
                try NoteStore.markPushed(snapshots: snapshots)
            }
            if notes.count < 200 && snapshots.count < 500 { return }
        }
    }

    private func pull() async throws {
        // shortcut: a row committed out of seq order by a concurrent writer could be skipped until it changes again;
        // fine for one person's devices, switch to a server-side "changes since" function if that ever matters.
        func page<Row: Decodable>(_ table: String, _ columns: String, _ type: Row.Type) async throws -> [Row] {
            let cursor = NoteStore.syncValue("cursor.\(table)") ?? "0"
            let data = try await rest("\(table)?select=\(columns),seq&seq=gt.\(cursor)&order=seq.asc&limit=500", method: "GET")
            return try JSONDecoder().decode([Row].self, from: data)
        }
        while true {
            let notes = try await page("notes", "id,kind,target,label,body_md,created_at,updated_at,deleted_at", NoteStore.CloudNote.self)
            let snapshots = try await page("snapshots", "note_id,day,body_md,updated_at", NoteStore.CloudSnapshot.self)
            try NoteStore.applyRemote(notes: notes, snapshots: snapshots)
            if let last = notes.last?.seq { try NoteStore.setSyncValue("cursor.notes", String(last)) }
            if let last = snapshots.last?.seq { try NoteStore.setSyncValue("cursor.snapshots", String(last)) }
            if notes.count < 500 && snapshots.count < 500 { return }
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
    private func rest(_ path: String, method: String, body: [[String: Any]]? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: "rest/v1/\(path)", relativeTo: Self.projectURL)!)
        request.httpMethod = method
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        }
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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

extension NoteStore.CloudNote {
    /// Every column on every row: PostgREST takes a batch's columns from its first object, so nulls must be explicit.
    var row: [String: Any] {
        ["id": id, "kind": kind, "target": target, "label": label, "body_md": body_md,
         "created_at": created_at, "updated_at": updated_at, "deleted_at": deleted_at ?? NSNull()]
    }
}

extension NoteStore.CloudSnapshot {
    var row: [String: Any] { ["note_id": note_id, "day": day, "body_md": body_md, "updated_at": updated_at] }
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
        send(topic, "phx_join", ["config": ["postgres_changes": [["event": "*", "schema": "public", "table": "notes"]]],
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
