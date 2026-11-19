import AppKit
import Sparkle
import SwiftUI

@main
enum Main {
    static func main() {
        // Chrome/Brave launch this same binary as the native messaging host, passing the extension origin.
        if CommandLine.arguments.dropFirst().first?.hasPrefix("chrome-extension://") == true {
            NativeHost.run()
        }
        // AI apps (Claude, Codex, Gemini) launch it as an MCP server: MemoryNotes --mcp.
        if CommandLine.arguments.dropFirst().first == "--mcp" { MCPServer.run() }
        MemoryNotesApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let overlay = OverlayController()
    // scripts/install.sh removes SUFeedURL, so a dev build never starts Sparkle and never replaces itself with a release.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil, updaterDelegate: nil, userDriverDelegate: nil)
    func applicationDidFinishLaunching(_ notification: Notification) {
        BrowserBridge.registerThisApp()
        overlay.start()
        SearchPopup.shared.start()
        _ = CloudSync.shared  // starts syncing if it was turned on
    }

    /// memorynotes://auth-callback from a sync sign-in email.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { Task { await CloudSync.shared.handle(url) } }
    }
}

struct MemoryNotesApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("NoteAnywhere", id: "notes") {
            NotesWindow()
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            NotesCommands()
            CommandGroup(after: .appInfo) { CheckForUpdatesButton(updater: delegate.updaterController.updater) }
        }

        // "Open Note in New Window"
        WindowGroup("Note", id: "note", for: String.self) { $id in
            if let id { NoteWindow(noteID: id) }
        }
        .defaultSize(width: 640, height: 720)

        Settings {
            TabView {
                Form { AutoOpenToggle(); DateFormatPicker() }
                    .formStyle(.grouped)
                    .tabItem { Label("General", systemImage: "gearshape") }
                SyncSettingsView()
                    .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            }
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
        }

        Window("Keyboard Shortcuts", id: "shortcuts") {
            ShortcutsView()
        }
        .defaultSize(width: 480, height: 560)

        Window("Send Feedback", id: "feedback") {
            FeedbackView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Welcome to NoteAnywhere", id: "welcome") {
            WelcomeView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra("NoteAnywhere", systemImage: "note.text") {
            MenuContent(overlay: delegate.overlay, updater: delegate.updaterController.updater)
        }
    }
}

private struct NotesCommands: Commands {
    @FocusedValue(\.windowActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { actions?.newNote() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
            Button("New Note for Website") { actions?.newWebsiteNote() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Divider()
            Button("Lock All Notes") { LockSession.shared.lockNow() }  // locked notes close again, like Apple Notes' Lock Now
        }
        CommandGroup(after: .textEditing) {
            Button("Find Notes") { actions?.findNotes() }
                .keyboardShortcut("f")
                .disabled(actions == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            // Always asks for confirmation, since ⌘⌫ is also "delete to line start" while typing.
            Button("Delete Note…") { actions?.deleteSelected?() }
                .keyboardShortcut(.delete)
                .disabled(actions?.deleteSelected == nil)
        }
        CommandGroup(before: .toolbar) {
            Button("Notes") { actions?.show(.notes) }.keyboardShortcut("1")
            Button("Calendar") { actions?.show(.calendar) }.keyboardShortcut("2")
            Button("Graph") { actions?.show(.graph) }.keyboardShortcut("3")
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to NoteAnywhere") { openWindow(id: "welcome") }
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
                .keyboardShortcut("/", modifiers: [.command, .shift])
            Divider()
            Button("Send Feedback…") { openWindow(id: "feedback") }
        }
    }
}

private struct MenuContent: View {
    let overlay: OverlayController
    let updater: SPUUpdater
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Show/Hide Overlay") { overlay.toggle() }
            .keyboardShortcut("m", modifiers: [.option, .shift])  // shows the glyphs; the Carbon hotkey does the work
        Button("Search Notes") { SearchPopup.shared.toggle() }
            .keyboardShortcut(.space, modifiers: [.option, .shift])  // shows the glyphs; the Carbon hotkey does the work
        Button("Open Notes") {
            openWindow(id: "notes")
            NSApp.activate()
        }
        Button("Keyboard Shortcuts") {
            openWindow(id: "shortcuts")
            NSApp.activate()
        }
        // A menu item runs actions but not gestures, so activating here is what lets Settings take typing.
        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        Button("Send Feedback…") {
            openWindow(id: "feedback")
            NSApp.activate()
        }
        CheckForUpdatesButton(updater: updater)
        Divider()
        Button("Quit NoteAnywhere") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Greyed out while Sparkle is busy, and in dev builds, whose updater never starts. Sparkle's documented SwiftUI pattern.
private struct CheckForUpdatesButton: View {
    @ObservedObject private var model: Model
    init(updater: SPUUpdater) { model = Model(updater: updater) }

    var body: some View {
        Button("Check for Updates…") { model.updater.checkForUpdates() }
            .disabled(!model.canCheck)
    }

    final class Model: ObservableObject {
        let updater: SPUUpdater
        @Published var canCheck = false
        init(updater: SPUUpdater) {
            self.updater = updater
            updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        }
    }
}
