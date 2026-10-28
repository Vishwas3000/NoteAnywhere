import SwiftUI

/// Sync settings, shared by the Mac (Settings window) and iPhone (Settings tab).
struct SyncSettingsView: View {
    @ObservedObject private var sync = CloudSync.shared
    @State private var email = ""
    @State private var code = ""
    @State private var passphrase = ""
    @State private var confirm = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        Form {
            Section {
                Picker("Sync", selection: $sync.mode) {
                    Text("Off").tag(CloudSync.Mode.off)
                    Text("NoteAnywhere Cloud").tag(CloudSync.Mode.cloud)
                    Text("iCloud (coming soon)").tag(CloudSync.Mode.icloud).selectionDisabled()
                }
            } footer: {
                Text(sync.mode == .off
                     ? "Notes stay on this device only."
                     : "Notes sync between your Mac and iPhone. Each account only ever sees its own notes.")
            }

            if sync.mode == .cloud {
                if sync.email != nil, sync.vault == .create {
                    Section {
                        SecureField("Sync passphrase", text: $passphrase)
                        SecureField("Type it again", text: $confirm)
                        Button("Turn On Encrypted Sync") { Task { await sync.createVault(passphrase: passphrase); clear() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(passphrase.count < 8 || passphrase != confirm || sync.busy)
                    } header: {
                        Text("Encrypt your notes")
                    } footer: {
                        Text("Your notes are encrypted on this device before they're uploaded; the server can't read them. Use at least 8 characters. Your other devices ask for this passphrase once. If you forget it, the synced copy can't be read (the notes on your devices are fine).")
                    }
                } else if sync.email != nil, sync.vault == .enter {
                    Section {
                        SecureField("Sync passphrase", text: $passphrase).onSubmit(enter)
                        Button("Unlock Synced Notes", action: enter)
                            .buttonStyle(.borderedProminent)
                            .disabled(passphrase.isEmpty || sync.busy)
                    } header: {
                        Text("Enter your sync passphrase")
                    } footer: {
                        Text("You chose it when you first turned on sync on another device.")
                    }
                } else if sync.email != nil, sync.vault == nil {
                    Section { ProgressView("Checking your account…") }
                }
                if let account = sync.email {
                    Section("Account") {
                        LabeledContent("Signed in as", value: account)
                        LabeledContent("Last synced") {
                            if sync.busy { ProgressView().controlSize(.small) }
                            else { Text(sync.lastSynced.map { $0.formatted(.relative(presentation: .named)) } ?? "Not yet") }
                        }
                        Button("Sync Now") { sync.syncNow() }.disabled(sync.busy)
                        Button("Sign Out", role: .destructive) { sync.signOut() }
                    }
                } else if let sentTo = sync.pendingEmail {
                    Section {
                        Label("Open the email on this device and click its link. It brings you back here, signed in.",
                              systemImage: "envelope.open")
                        TextField("Or enter the code from the email", text: $code)
                            .focused($codeFocused)
                            .textContentType(.oneTimeCode)
                            .onSubmit(verify)
                        HStack {
                            Button("Use a Different Email") { sync.cancelCode(); code = "" }
                            Spacer()
                            Button("Sign In", action: verify)
                                .buttonStyle(.borderedProminent)
                                .disabled(!(6...8).contains(code.filter(\.isNumber).count) || sync.busy)
                        }
                    } header: {
                        Text("Check your email")
                    } footer: {
                        Text("We sent a sign-in link to \(sentTo). It expires in an hour.")
                    }
                    .onAppear { codeFocused = true }
                } else {
                    Section {
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .autocorrectionDisabled()
                            .onSubmit(sendLink)
                        Button("Email Me a Sign-In Link", action: sendLink)
                            .buttonStyle(.borderedProminent)
                            .disabled(!email.contains("@") || sync.busy)
                    } header: {
                        Text("Sign in to sync")
                    } footer: {
                        Text("No password: we email you a one-time sign-in link.")
                    }
                }
            }

            if let error = sync.error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .tint(.notesAccent)
    }

    private func sendLink() {
        guard email.contains("@") else { return }
        Task { await sync.sendLink(to: email) }
    }

    private func enter() { Task { await sync.enterVault(passphrase: passphrase); clear() } }

    private func clear() {
        if sync.vault == .ready {
            passphrase = ""
            confirm = ""
        }
    }

    private func verify() {
        Task {
            await sync.verify(code: code)
            if sync.email != nil { code = "" }
        }
    }
}
