import AppKit
import OSLog
import SwiftUI
import Testing
@testable import MemoryNotes

/// Opt-in (MN_UI_PROBE=1): hosts the real main window off-screen and drags the sidebar divider, with the inspector
/// hidden and shown. On macOS 26 the note pane runs under the floating sidebar; on 2026-11-20 an inspector inside the
/// note pane counted the sidebar's width twice (pane = 2 × sidebar + 40), so the pane outgrew the window, the window
/// fed that back every frame (×1.5 a frame), RenderBox asked for 663-million-pixel textures, the window drew blank and
/// the Mac stalled (D78).
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["MN_UI_PROBE"] != nil), arguments: [false, true])
func sidebarDragKeepsTheNotePaneInsideTheWindow(inspectorShown: Bool) throws {
    _ = SyncStoreTests.dir  // the scratch store, never the real notes
    #expect(NoteStore.root.path == SyncStoreTests.dir, "would touch the real notes database")
    guard NoteStore.root.path == SyncStoreTests.dir else { return }
    if NotesModel.shared.notes.count < 12 {
        for i in 0..<12 { _ = NotesModel.shared.add(kind: .url, target: "example.com/\(i)", label: "", text: "Note \(i)\n#project-\(i % 3) #bug") }
    }
    UserDefaults.standard.set(inspectorShown, forKey: "inspectorShown")
    defer { UserDefaults.standard.removeObject(forKey: "inspectorShown") }

    _ = NSApplication.shared
    let width: CGFloat = 1400
    let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: 0, width: width, height: 860),
                                 styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: NotesWindow())
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.contentView = nil }
    spin(1.0)

    let split = try #require(first(NSSplitView.self, in: window.contentView!), "no split view: the window didn't build")
    var widestPane: CGFloat = 0, widestBox: CGFloat = 0
    for x in Array(stride(from: 300, through: 1000, by: 25)) + Array(stride(from: 1000, through: 300, by: -50)) {
        split.setPosition(CGFloat(x), ofDividerAt: 0)
        spin(0.05)
        widestPane = max(widestPane, split.arrangedSubviews.map(\.frame.width).max() ?? 0)
        widestBox = max(widestBox, widest(in: window.contentView!))
    }
    // The inspector must still be there when shown: some view of its column's width (220-360) on the trailing edge.
    if inspectorShown {
        let trailing = allViews(in: window.contentView!).filter {
            let f = $0.convert($0.bounds, to: nil); return (219...361).contains(f.width) && abs(f.maxX - width) < 2 && f.height > 400
        }
        #expect(!trailing.isEmpty, "the inspector isn't showing")
    }
    let textureErrors = try OSLogStore(scope: .currentProcessIdentifier).getEntries()
        .compactMap { $0 as? OSLogEntryLog }.filter { $0.composedMessage.contains("unable to create texture") }.count
    #expect(widestPane <= width + 1, "a pane grew to \(Int(widestPane)) in a \(Int(width))-point window")
    #expect(widestBox < 4 * width, "a view or layer ran away to \(Int(widestBox)) points")
    #expect(textureErrors == 0)
}

/// macOS moves titled windows back onto a screen; this one stays off every screen, so the probe is never seen.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor private func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

@MainActor private func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    return view.subviews.lazy.compactMap { first(type, in: $0) }.first
}

@MainActor private func allViews(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { allViews(in: $0) } }

/// The widest view frame or layer bound anywhere under `view`; layers too, because RenderBox draws into them.
@MainActor private func widest(in view: NSView) -> CGFloat {
    func layers(_ layer: CALayer) -> CGFloat { (layer.sublayers ?? []).reduce(layer.bounds.width) { max($0, layers($1)) } }
    let own = max(view.frame.width, view.layer.map(layers) ?? 0)
    return view.subviews.reduce(own) { max($0, widest(in: $1)) }
}
