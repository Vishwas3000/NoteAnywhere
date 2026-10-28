import LocalAuthentication
import SwiftUI

/// Shown instead of the editor while a note is locked: Touch ID, or the notes password.
struct LockedNoteView: View {
    var compact = false  // overlay cards and search results
    @ObservedObject private var lock = LockSession.shared
    @State private var password = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: compact ? 6 : 12) {
            Image(systemName: "lock.fill").font(compact ? .title3 : .largeTitle).foregroundStyle(.secondary)
            Text("This note is locked.").font(compact ? .callout.weight(.semibold) : .title3.weight(.semibold))
            if lock.canUseBiometrics {
                Button { Task { await biometrics() } } label: { Label("Unlock with \(Self.biometryName)", systemImage: "touchid") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(compact ? .small : .regular)
            }
            HStack {
                SecureField("Notes password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(unlock)
                Button("Unlock", action: unlock).disabled(password.isEmpty)
            }
            .frame(maxWidth: 280)
            .controlSize(compact ? .small : .regular)
            if let hint = lock.hint, !compact { Text("Hint: \(hint)").font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(compact ? 8 : 24)
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity)
        .accessibilityElement(children: .contain)
    }

    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .faceID ? "Face ID" : "Touch ID"
    }

    private func unlock() {
        do {
            try lock.unlock(with: password)
            password = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func biometrics() async {
        do { try await lock.unlockWithBiometrics(); error = nil } catch { self.error = error.localizedDescription }
    }
}

/// The first time a note is locked: choose the notes password, like Apple Notes.
struct NotesPasswordSheet: View {
    let done: (Bool) -> Void  // true once a password is set
    @State private var password = ""
    @State private var confirm = ""
    @State private var hint = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set a Password for Locked Notes").font(.headline)
            Text("Locked notes are encrypted with this password, here and wherever they sync. \(LockedNoteView.biometryName) can unlock them on this device.")
                .font(.callout).foregroundStyle(.secondary)
            SecureField("Password", text: $password)
            SecureField("Verify", text: $confirm)
            TextField("Hint (recommended)", text: $hint)
            Label("If you forget this password, your locked notes can't be recovered.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(false) }
                Button("Set Password") {
                    do {
                        try LockSession.shared.setPassword(password, hint: hint)
                        done(true)
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(password.count < 4 || password != confirm || password == hint)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 400)
        .tint(.notesAccent)
    }
}
