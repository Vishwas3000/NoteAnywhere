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
        MenuBarExtra("MemoryNotes", systemImage: "note.text") {
            MenuContent(overlay: delegate.overlay)
        }
    }
}

private struct MenuContent: View {
    let overlay: OverlayController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show/Hide Overlay") { overlay.toggle() }
        Button("Search Notes  ⌥⇧Space") { SearchPopup.shared.toggle() }
        Button("Open Notes") {
            openWindow(id: "notes")
            NSApp.activate()
        }
        Divider()
        Button("Quit MemoryNotes") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
