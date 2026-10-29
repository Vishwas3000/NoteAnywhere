import Foundation
import OSLog
import Testing
@testable import MemoryNotes

@MainActor
@Test func viewSwitchIsTimedAndLogged() async throws {
    let started = Date()
    Perf.begin("Notes → Calendar")
    Perf.end()
    try await Task.sleep(for: .milliseconds(100))  // Perf.end logs on the next main-queue turn
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let lines = try store.getEntries(at: store.position(date: started),
                                     matching: NSPredicate(format: "subsystem == 'com.memorynotes.app' AND category == 'perf'"))
        .compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
    #expect(lines.contains { $0.wholeMatch(of: #/Notes → Calendar: \d+ ms, CPU \d+ ms, memory \d+ MB/#) != nil }, "\(lines)")
}
