import XCTest

/// End to end in the simulator: share a page from Safari to MemoryNotes, then find the note in the app.
final class ShareFromSafariTests: XCTestCase {
    func testSharePageFromSafari() throws {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.terminate()
        safari.open(URL(string: "https://example.com/")!)
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20))

        // Safari 26 keeps Share in the toolbar's More menu; older layouts show it directly.
        let share = safari.buttons["Share"]
        if !share.waitForExistence(timeout: 10) { safari.buttons["More"].firstMatch.tap() }
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()

        let target = safari.cells["MemoryNotes"].firstMatch
        if !target.waitForExistence(timeout: 10) {
            safari.cells["More"].firstMatch.tap()  // not in the first row: pick it from the full list
        }
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
        let row = app.staticTexts["Shared from Safari"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["example.com"].exists)
    }
}
