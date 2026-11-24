import AppKit
import Testing
@testable import MemoryNotes

/// Settings ▸ General ▸ Appearance sets the whole app's appearance; Automatic leaves it to the Mac (D85).
@MainActor
@Test func appearanceSetsTheAppsAppearance() {
    _ = NSApplication.shared
    defer { NSApp.appearance = nil }
    Appearance.apply(.dark)
    #expect(NSApp.appearance?.name == .darkAqua)
    Appearance.apply(.light)
    #expect(NSApp.appearance?.name == .aqua)
    Appearance.apply(.automatic)
    #expect(NSApp.appearance == nil)
    #expect(Appearance(rawValue: "sepia") == nil, "an unknown saved value falls back to Automatic")
}
