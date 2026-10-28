import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        // Chrome/Brave launch this same binary as the native messaging host, passing the extension origin.
        if CommandLine.arguments.dropFirst().first?.hasPrefix("chrome-extension://") == true {
            NativeHost.run()
        }
        MemoryNotesApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let overlay = OverlayController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay.start()
        SearchPopup.shared.start()
    }
}

struct MemoryNotesApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("MemoryNotes", id: "notes") {
            NotesWindow()
        }
        .defaultSize(width: 960, height: 640)
        .commands { NotesCommands() }

        Window("Keyboard Shortcuts", id: "shortcuts") {
            ShortcutsView()
        }
        .defaultSize(width: 480, height: 560)

        MenuBarExtra("MemoryNotes", systemImage: "note.text") {
            MenuContent(overlay: delegate.overlay)
        }
    }
}

private struct NotesCommands: Commands {
    @FocusedValue(\.windowActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Website Note") { actions?.newWebsiteNote() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
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
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
                .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }
}

private struct MenuContent: View {
    let overlay: OverlayController
    @Environment(\.openWindow) private var openWindow

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
        Divider()
        Button("Quit MemoryNotes") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
