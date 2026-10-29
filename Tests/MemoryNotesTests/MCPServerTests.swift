import Foundation
import Testing
@testable import MemoryNotes

@Test func mcpTicksOnlyChecklistLines() {
    let text = "Plan\n- [ ] call @2026-10-30\n  * [x] nested\n- plain"
    #expect(MCPServer.settingTask(text, line: 1, done: true) == "Plan\n- [x] call @2026-10-30\n  * [x] nested\n- plain")
    #expect(MCPServer.settingTask(text, line: 2, done: false) == "Plan\n- [ ] call @2026-10-30\n  * [ ] nested\n- plain")
    #expect(MCPServer.settingTask(text, line: 0, done: true) == nil)
    #expect(MCPServer.settingTask(text, line: 3, done: true) == nil)
    #expect(MCPServer.settingTask(text, line: 9, done: true) == nil)
}

@Test func mcpSnippetIsOneLineAroundTheFirstHit() {
    let text = String(repeating: "a", count: 100) + "\nThe Printer quote\n" + String(repeating: "b", count: 200)
    let snippet = MCPServer.snippet(text, "printer cost")!
    #expect(snippet.hasPrefix("…") && snippet.hasSuffix("…") && snippet.contains("The Printer quote"))
    #expect(!snippet.contains("\n"))
    #expect(MCPServer.snippet("short note", "nothing here") == nil)
}

@Test func mcpReadsDaysAndDateTimes() {
    #expect(MCPServer.parseDate("2026-10-01") != nil)
    #expect(MCPServer.parseDate("2026-10-01T09:30:00Z") == Date(timeIntervalSince1970: 1_790_847_000))
    #expect(MCPServer.parseDate("last week") == nil)
}
