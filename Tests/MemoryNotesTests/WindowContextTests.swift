@testable import MemoryNotes
import Testing

@Test(arguments: [
    // Slack: narrow first, app last; unread counts dropped.
    ("Alex Rivera (DM) - Acme - 8 new items - Slack", "Slack", ["Acme", "Alex Rivera (DM)"]),
    ("general (Channel) - Acme - Slack", "Slack", ["Acme", "general (Channel)"]),
    ("general (Channel) - Acme - 1 new item - Slack", "Slack", ["Acme", "general (Channel)"]),
    // VS Code: unsaved dot dropped, em-dash separators.
    ("● Note.swift — memoryNotes — Visual Studio Code", "Code", ["memoryNotes", "Note.swift"]),
    // Browser whose app name is longer than its title suffix.
    ("ChatGPT - Brave", "Brave Browser", ["ChatGPT"]),
    // Xcode: broad first, no app name.
    ("memoryNotes — Note.swift", "Xcode", ["memoryNotes", "Note.swift"]),
    // Counts in front or behind.
    ("(3) Inbox - Mail", "Mail", ["Inbox"]),
    ("Inbox (12)", "Mail", ["Inbox"]),
    // A "/" inside a name must not create a level.
    ("a/b.txt", "TextEdit", ["a∕b.txt"]),
    // Window titled just like the app, or nothing.
    ("Slack", "Slack", []),  // no "Slack › Slack"
    ("", "Slack", []),
])
func windowTitlePath(title: String, app: String, expected: [String]) {
    #expect(WindowContext.path(title: title, appName: app) == expected)
}

@Test func targetAndPlace() {
    let target = WindowContext.target(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
                                      title: "Alex Rivera (DM) - Acme - Slack")
    #expect(target == "com.tinyspeck.slackmacgap/Acme/Alex Rivera (DM)")
    #expect(Note(kind: .app, target: target, label: "Slack").place == "Slack › Acme › Alex Rivera (DM)")
    #expect(WindowContext.target(bundleID: "com.apple.finder", appName: "Finder", title: nil) == "com.apple.finder")
}

@Test func websitePlace() {
    let slack = Note(kind: .url, target: "app.slack.com/client/T01/D02", label: "Alex Rivera (DM) - Acme - Slack")
    #expect(slack.place == "app.slack.com › Acme › Alex Rivera (DM)")
    #expect(Note(kind: .url, target: "github.com/a/b", label: "").place == "github.com/a/b")
}

@Test func conversationFromInsideTheWindow() {
    // WhatsApp's title is only "\u{200E}WhatsApp"; the chat comes from its header element.
    #expect(WindowContext.path(title: "\u{200E}WhatsApp", appName: "WhatsApp") == [])
    let target = WindowContext.target(bundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp", title: "\u{200E}WhatsApp",
                                      conversation: "\u{200E}Project / Team")
    #expect(target == "net.whatsapp.WhatsApp/Project ∕ Team")
    #expect(Note(kind: .app, target: target, label: "WhatsApp").place == "WhatsApp › Project ∕ Team")
    // A title that already names the place wins over the header.
    #expect(WindowContext.target(bundleID: "x", appName: "Slack", title: "general - Acme - Slack", conversation: "other")
            == "x/Acme/general")
}
