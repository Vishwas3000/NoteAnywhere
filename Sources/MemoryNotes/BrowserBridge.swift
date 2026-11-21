import Foundation

/// Registers this app as the native messaging host of every installed Chromium browser and Firefox, so a downloaded
/// app reaches the extension with no install script. Runs at each launch; a manifest is rewritten only when it differs
/// (app moved).
enum BrowserBridge {
    static let hostName = "com.memorynotes.host"
    /// The unpacked extension's id, pinned by the "key" in extension/manifest.json (D3).
    static let devExtensionID = "fmjimldgmehkakonbffiaacmpijhajop"
    /// Firefox's id for the add-on, fixed by browser_specific_settings.gecko.id in extension/manifest.json (D81).
    static let firefoxAddonID = "noteanywhere@noteanywhere.app"
    /// The id the Chrome Web Store assigned; apps from before it was set only trust the unpacked one.
    static let storeExtensionID = "fngldbimlphnokkkkodneojgbdnofjha"
    /// Set once the store approves the listing; until then its page says "not found".
    static let storeListed = false
    /// Where to get the extension: its Web Store page once listed; until then the latest release, whose notes say how to
    /// load it unpacked.
    static var extensionPage: URL {
        URL(string: storeListed ? "https://chromewebstore.google.com/detail/\(storeExtensionID)"
                                : "https://github.com/Vishwas3000/NoteAnywhere/releases/latest")!
    }

    /// User-data folders under ~/Library/Application Support; each browser reads NativeMessagingHosts/ inside its own.
    static let browsers = ["Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Chromium",
                           "BraveSoftware/Brave-Browser", "Microsoft Edge", "Arc/User Data", "Vivaldi"]

    /// Firefox (every channel) keeps its profiles in Firefox/ and reads hosts from Mozilla/NativeMessagingHosts/.
    static let firefoxFolder = "Firefox", firefoxHosts = "Mozilla/NativeMessagingHosts"

    /// Chrome's manifest lists extension origins; Firefox's lists add-on ids instead.
    static func manifest(executable: String, firefox: Bool = false) -> Data {
        var json: [String: Any] = ["name": hostName, "description": "NoteAnywhere", "path": executable, "type": "stdio"]
        if firefox {
            json["allowed_extensions"] = [firefoxAddonID]
        } else {
            json["allowed_origins"] = [devExtensionID, storeExtensionID].filter { !$0.isEmpty }.map { "chrome-extension://\($0)/" }
        }
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
        let chromium = manifest(executable: executable)
        let targets = browsers.map { (browser: $0, hosts: "\($0)/NativeMessagingHosts", data: chromium) }
            + [(browser: firefoxFolder, hosts: firefoxHosts, data: manifest(executable: executable, firefox: true))]
        for (browser, hosts, data) in targets where FileManager.default.fileExists(atPath: support.appendingPathComponent(browser).path) {
            let file = support.appendingPathComponent("\(hosts)/\(hostName).json")
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
