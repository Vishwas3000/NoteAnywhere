import SwiftUI

/// The app's version, as release.sh stamps it ("dev" under `swift run`, which has no Info.plist).
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

/// Sends a problem or a suggestion to the developer without leaving the app: noteanywhere.app/api/feedback emails it
/// (worker/index.js, D72). A failed send keeps the text and offers Mail instead. Shared with the iPhone app (Settings).
struct FeedbackView: View {
    static let endpoint = URL(string: "https://noteanywhere.app/api/feedback")!
    #if os(iOS)
    static let about = "NoteAnywhere \(appVersion), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    #else
    static let about = "NoteAnywhere \(appVersion), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    #endif

    enum Kind: String, CaseIterable { case problem = "Problem", idea = "Suggestion" }
    private enum Status: Equatable { case editing, sending, sent, failed(String) }

    @State private var kind = Kind.problem
    @State private var message = ""
    @State private var email = ""
    @State private var status = Status.editing
    @Environment(\.dismiss) private var dismiss  // closes the Mac window, or goes back in iPhone Settings
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if status == .sent {
                ContentUnavailableView {
                    Label("Feedback Sent", systemImage: "checkmark.circle")
                } description: {
                    Text(email.isEmpty ? "Thank you." : "Thank you. Replies go to \(email).")
                } actions: {
                    Button("Done") { reset(); dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                form
            }
        }
        #if os(macOS)
        .padding(20)
        .frame(width: 440)
        #else
        .padding()
        .navigationTitle("Send Feedback")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Kind", selection: $kind) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextEditor(text: $message)
                .font(.body)
                .frame(height: 160)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text(kind == .problem ? "What went wrong, and what were you doing?" : "What would make NoteAnywhere better?")
                            .foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Message")

            TextField("Your email, if you'd like a reply", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
                #if os(iOS)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif

            Text("Sent with \(Self.about).").font(.caption).foregroundStyle(.secondary)

            if case .failed(let reason) = status {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
                    .accessibilityAddTraits(.isStaticText)
            }

            HStack {
                if case .failed = status {
                    Button("Email Instead") { openURL(mailto) }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(status == .sending ? "Sending…" : "Send") { Task { await send() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || status == .sending)
            }
        }
    }

    private var mailto: URL {
        var c = URLComponents(string: "mailto:timeupvishwa@gmail.com")!
        c.queryItems = [URLQueryItem(name: "subject", value: "NoteAnywhere \(kind.rawValue.lowercased())"),
                        URLQueryItem(name: "body", value: "\(message)\n\n--\n\(Self.about)")]
        return c.url!
    }

    private func reset() {
        message = ""; status = .editing
    }

    private func send() async {
        status = .sending
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "kind": kind == .problem ? "problem" : "idea", "message": message,
            "email": email.trimmingCharacters(in: .whitespaces), "app": Self.about,
        ])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { status = .sent; return }
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            NSLog("MemoryNotes: feedback failed with HTTP \(code): \(reason ?? "no reason")")
            status = .failed(reason ?? "The feedback server answered \(code). Try again, or email instead.")
        } catch {
            NSLog("MemoryNotes: feedback failed: \(error)")
            status = .failed("Couldn't reach noteanywhere.app: \(error.localizedDescription)")
        }
    }
}
