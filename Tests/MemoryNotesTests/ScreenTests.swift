import AppKit
import Testing
@testable import MemoryNotes

@Test func panelKeepsTopRightOffsetOnNewScreen() {
    let main = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let left = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
    let panel = NSRect(x: 1120, y: 540, width: 300, height: 340)  // 20 from the right, 20 from the top
    #expect(NSPanel.origin(of: panel, from: main, to: left) == NSPoint(x: -320, y: 720))
}

@Test func panelStaysOnSmallerScreen() {
    let big = NSRect(x: 0, y: 0, width: 2560, height: 1440)
    let small = NSRect(x: 2560, y: 0, width: 800, height: 600)
    let panel = NSRect(x: 0, y: 0, width: 300, height: 340)  // bottom-left of the big screen
    #expect(NSPanel.origin(of: panel, from: big, to: small) == NSPoint(x: 2560, y: 0))
}
