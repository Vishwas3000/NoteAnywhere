import AppKit
import SwiftUI

/// Shown once, on first launch (Help ▸ Welcome to NoteAnywhere brings it back): the two things that let notes follow
/// you, Accessibility for the chat or file in front and the browser extension for web pages.
struct WelcomeView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                Text("Welcome to NoteAnywhere").font(.title2.bold())
                Text("Notes that show up where they belong.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Text("Notes follow the chat, DM or channel you're in. Write one in #design-review, and it's there the next time you are.")
                .fixedSize(horizontal: false, vertical: true)

            step(1, "Allow Accessibility", "So notes can follow the chat, channel or file you're in, not just the app.",
                 done: trusted ? "Allowed" : nil) {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
            step(2, "Add the browser extension",
                 "Your notes on the web pages they're about, in Chrome, Brave, Edge or Arc. Edit a note in either place and the other updates.") {
                Button("Get the Extension") { NSWorkspace.shared.open(BrowserBridge.extensionPage) }
            }

            HStack {
                Spacer()
                Button("Get Started") { dismissWindow(id: "welcome") }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 440)
        .tint(.notesAccent)
        // Back from System Settings: show the tick.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = AXIsProcessTrusted()
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String, done: String? = nil,
                      @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done == nil ? "\(number).circle.fill" : "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(done == nil ? Color.notesAccent : .green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let done { Text(done).foregroundStyle(.secondary) } else { action() }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
