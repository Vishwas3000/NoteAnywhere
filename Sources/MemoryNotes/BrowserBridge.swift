import Foundation

/// Registers this app as the native messaging host of every installed Chromium browser, so a downloaded app reaches
/// the extension with no install script. Runs at each launch; a manifest is rewritten only when it differs (app moved).
enum BrowserBridge {
    static let hostName = "com.memorynotes.host"
    /// The unpacked extension's id, pinned by the "key" in extension/manifest.json (D3).
    static let devExtensionID = "fmjimldgmehkakonbffiaacmpijhajop"
    /// FILL IN: the id the Chrome Web Store assigns on the first upload (docs/RELEASING.md), then ship a new app release.
    static let storeExtensionID = ""

    /// User-data folders under ~/Library/Application Support; each browser reads NativeMessagingHosts/ inside its own.
    static let browsers = ["Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Chromium",
                           "BraveSoftware/Brave-Browser", "Microsoft Edge", "Arc/User Data", "Vivaldi"]

    static func manifest(executable: String) -> Data {
        let origins = [devExtensionID, storeExtensionID].filter { !$0.isEmpty }.map { "chrome-extension://\($0)/" }
        let json: [String: Any] = ["name": hostName, "description": "NoteAnywhere", "path": executable, "type": "stdio",
                                   "allowed_origins": origins]
        return try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Skips `swift run` builds and translocated copies (a quarantined app opened in place): their paths don't last.
    static func registerThisApp() {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app", !bundle.bundlePath.contains("/AppTranslocation/"),
              let executable = bundle.executablePath else { return }
        register(executable: executable)
    }

    static func register(executable: String,
                         support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        let data = manifest(executable: executable)
        for browser in browsers where FileManager.default.fileExists(atPath: support.appendingPathComponent(browser).path) {
            let file = support.appendingPathComponent("\(browser)/NativeMessagingHosts/\(hostName).json")
            if (try? Data(contentsOf: file)) == data { continue }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                NSLog("MemoryNotes: can't register the browser bridge for \(browser): \(error)")
            }
        }
    }
}
