import AuthenticationServices
import SwiftUI

/// Sync settings, shared by the Mac (Settings window) and iPhone (Settings tab).
struct SyncSettingsView: View {
    @ObservedObject private var sync = CloudSync.shared
    @State private var email = ""
    @State private var code = ""
    @State private var passphrase = ""
    @State private var confirm = ""
    @FocusState private var codeFocused: Bool
    @FocusState private var passphraseFocus: PassphraseField?
    private enum PassphraseField { case first, again }
    @Environment(\.webAuthenticationSession) private var webAuthentication

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
                        // A placeholder makes the field visible: on the Mac, clicking a form label doesn't focus its field.
                        SecureField("Sync passphrase", text: $passphrase, prompt: Text("At least 8 characters"))
                            .focused($passphraseFocus, equals: .first)
                            .onSubmit { passphraseFocus = .again }
                        SecureField("Type it again", text: $confirm, prompt: Text("The same passphrase"))
                            .focused($passphraseFocus, equals: .again)
                            .onSubmit(create)
                        if let hint = passphraseHint { Text(hint).foregroundStyle(.secondary) }
                        Button("Turn On Encrypted Sync", action: create)
                            .buttonStyle(.borderedProminent)
                            .disabled(!passphraseIsValid || sync.busy)
                    } header: {
                        Text("Last step: choose a sync passphrase")
                    } footer: {
                        Text("Your notes are encrypted with it on this device before they're uploaded, so the server can't read them. Each of your other devices asks for it once. Keep it in your password manager: if you forget it, the synced copy can't be opened (the notes on your devices are fine).")
                    }
                    .onAppear { passphraseFocus = .first }
                } else if sync.email != nil, sync.vault == .enter {
                    Section {
                        SecureField("Sync passphrase", text: $passphrase, prompt: Text("The one you chose before"))
                            .focused($passphraseFocus, equals: .first)
                            .onSubmit(enter)
                        Button("Unlock Synced Notes", action: enter)
                            .buttonStyle(.borderedProminent)
                            .disabled(passphrase.isEmpty || sync.busy)
                    } header: {
                        Text("Enter your sync passphrase")
                    } footer: {
                        Text("You chose it when you first turned on sync on another device.")
                    }
                    .onAppear { passphraseFocus = .first }
                } else if sync.email != nil, sync.vault == nil {
                    Section { ProgressView("Checking your account…") }
                }
                if let account = sync.email {
                    Section("Account") {
                        LabeledContent("Signed in as", value: account)
                        if sync.vault == .ready {  // before the passphrase there's nothing to sync, so no dead button
                            LabeledContent("Last synced") {
                                if sync.busy { ProgressView().controlSize(.small) }
                                else { Text(sync.lastSynced.map { $0.formatted(.relative(presentation: .named)) } ?? "Not yet") }
                            }
                            Button("Sync Now") { sync.syncNow() }.disabled(sync.busy)
                        }
                        Button("Sign Out", role: .destructive) { sync.signOut() }
                    }
                } else if let sentTo = sync.pendingEmail {
                    Section {
                        Label("Open the email on this device and click its link. It brings you back here, signed in.",
                              systemImage: "envelope.open")
                        TextField("Or enter the code from the email", text: $code, prompt: Text("Code from the email"))
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
                        Button { Task { await signInWithGoogle() } } label: {
                            Label("Continue with Google", systemImage: "person.crop.circle.badge.checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .disabled(sync.busy)
                    }
                    Section {
                        TextField("Email", text: $email, prompt: Text("you@example.com"))
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

    /// Google's page opens in a secure sheet (shared with Safari's sign-ins); its redirect carries the session.
    private func signInWithGoogle() async {
        do {
            let url = try await webAuthentication.authenticate(using: CloudSync.googleURL, callbackURLScheme: "memorynotes")
            await sync.handle(url)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // closed the sheet: nothing to report
        } catch {
            sync.error = error.localizedDescription
        }
    }

    private func sendLink() {
        guard email.contains("@") else { return }
        Task { await sync.sendLink(to: email) }
    }

    private func enter() { Task { await sync.enterVault(passphrase: passphrase); clear() } }

    private var passphraseIsValid: Bool { passphrase.count >= 8 && passphrase == confirm }

    /// Why Turn On is still greyed out, once there's something typed to explain.
    private var passphraseHint: String? {
        let missing = 8 - passphrase.count
        if passphrase.isEmpty { return nil }
        if missing > 0 { return missing == 1 ? "1 more character to go." : "\(missing) more characters to go." }
        if !confirm.isEmpty, confirm != passphrase { return "The two passphrases don't match yet." }
        return nil
    }

    private func create() {
        guard passphraseIsValid, !sync.busy else { return }
        Task { await sync.createVault(passphrase: passphrase); clear() }
    }

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
