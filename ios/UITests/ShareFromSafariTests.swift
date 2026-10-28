import XCTest

/// End to end in the simulator: share a page from Safari to NoteAnywhere, find the note in the app, then turn the
/// Safari extension on and see the same note in the page's overlay (read through the extension's native handler).
final class ShareFromSafariTests: XCTestCase {
    func testShareAPageThenSeeItInTheOverlay() throws {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.terminate()
        // A fresh address each run (same note target: the query is ignored), so Safari doesn't restore an old tab state.
        let page = URL(string: "https://example.com/?run=\(Int(Date().timeIntervalSince1970))")!
        safari.open(page)
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20))

        // Safari 26 keeps Share in the toolbar's More menu; older layouts show it directly.
        let share = safari.buttons["Share"]
        if !share.waitForExistence(timeout: 10) { safari.buttons["More"].firstMatch.tap() }
        if !share.waitForExistence(timeout: 10) { print("MENU", safari.debugDescription) }
        XCTAssertTrue(share.exists)
        share.tap()
        let target = safari.cells["NoteAnywhere"].firstMatch
        if !target.waitForExistence(timeout: 10) { safari.cells["More"].firstMatch.tap() }  // pick it from the full list
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.tap()

        let field = safari.textViews.firstMatch.exists ? safari.textViews.firstMatch : safari.textFields["Write a note…"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(safari.staticTexts["example.com"].waitForExistence(timeout: 5), "the page's target")
        field.tap()
        field.typeText("Shared from Safari")
        safari.buttons["Save"].tap()

        let app = XCUIApplication()
        app.launchArguments = ["-tab", "notes", "-openNote", "", "-search", ""]
        app.launch()
        XCTAssertTrue(app.staticTexts["Shared from Safari"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["example.com"].firstMatch.exists)

        try enableExtension()
        safari.terminate()
        safari.open(page)
        let note = safari.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Shared from Safari'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20), "the overlay lists the page's note")
        let shot = XCTAttachment(screenshot: safari.screenshot())
        shot.name = "overlay"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Settings › Apps › Safari › Extensions › NoteAnywhere: allow it, on all websites.
    private func enableExtension() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        for _ in 0..<6 where settings.buttons["BackButton"].exists { settings.buttons["BackButton"].tap() }  // it reopens where it was
        for name in ["Apps", "Safari", "Extensions", "NoteAnywhere"] { try open(name, in: settings) }
        let allow = settings.switches["Allow Extension"].firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        if allow.value as? String == "0" { allow.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }  // the toggle, not the label
        let sites = settings.staticTexts["All Websites"].firstMatch.waitForExistence(timeout: 5) ? "All Websites" : "Other Websites"
        guard !settings.cells.containing(.staticText, identifier: sites).staticTexts["Allow"].exists else { return }  // a re-run
        try open(sites, in: settings)
        try open("Allow", in: settings)
    }

    /// Taps a row by its title, scrolling down to it first.
    private func open(_ name: String, in app: XCUIApplication) throws {
        let row = app.cells.containing(.staticText, identifier: name).firstMatch
        let screen = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 100)  // clear of the bars
        for _ in 0..<12 where !(row.exists && screen.contains(CGPoint(x: row.frame.midX, y: row.frame.midY))) { app.swipeUp() }
        guard row.exists else { throw XCTSkip("Settings has no \(name) row on this iOS version") }
        row.tap()
    }
}
