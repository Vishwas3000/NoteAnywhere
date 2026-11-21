import CryptoKit
import Foundation
import Testing
@testable import MemoryNotes

@Test func hostManifestPointsAtTheAppAndAllowsTheExtension() throws {
    let path = "/Applications/NoteAnywhere.app/Contents/MacOS/MemoryNotes"
    let json = try #require(try JSONSerialization.jsonObject(with: BrowserBridge.manifest(executable: path)) as? [String: Any])
    #expect(json["name"] as? String == "com.memorynotes.host")
    #expect(json["path"] as? String == path)
    #expect(json["type"] as? String == "stdio")
    #expect((json["allowed_origins"] as? [String])?.first == "chrome-extension://fmjimldgmehkakonbffiaacmpijhajop/")
}

@Test func firefoxManifestAllowsTheAddonByItsID() throws {
    let json = try #require(try JSONSerialization.jsonObject(with: BrowserBridge.manifest(executable: "/a/MemoryNotes", firefox: true))
        as? [String: Any])
    #expect(json["name"] as? String == "com.memorynotes.host")
    #expect(json["path"] as? String == "/a/MemoryNotes")
    #expect(json["allowed_extensions"] as? [String] == [BrowserBridge.firefoxAddonID])
    #expect(json["allowed_origins"] == nil)
}

@Test func firefoxAddonIDMatchesTheManifest() throws {
    let url = URL(fileURLWithPath: #filePath).appendingPathComponent("../../../extension/manifest.json").standardized
    let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let gecko = (manifest["browser_specific_settings"] as? [String: Any])?["gecko"] as? [String: Any]
    #expect(gecko?["id"] as? String == BrowserBridge.firefoxAddonID)
}

/// Chrome derives an unpacked extension's id from its manifest key: the first 32 hex of sha256(key), 0-f mapped to a-p.
@Test func devExtensionIDMatchesTheManifestKey() throws {
    let url = URL(fileURLWithPath: #filePath).appendingPathComponent("../../../extension/manifest.json").standardized
    let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let key = try #require((manifest["key"] as? String).flatMap { Data(base64Encoded: $0) })
    let hex = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined().prefix(32)
    let id = String(hex.map { Character(UnicodeScalar(UInt8(Int(String($0), radix: 16)!) + 97)) })
    #expect(id == BrowserBridge.devExtensionID)
}

@Test func registersOnlyInstalledBrowsersAndKeepsAnUnchangedFile() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("mn-bridge-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: support.appendingPathComponent("Arc/User Data"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: support) }

    BrowserBridge.register(executable: "/a/MemoryNotes", support: support)
    let file = support.appendingPathComponent("Arc/User Data/NativeMessagingHosts/com.memorynotes.host.json")
    #expect(try Data(contentsOf: file) == BrowserBridge.manifest(executable: "/a/MemoryNotes"))
    #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("Google").path))

    let written = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    BrowserBridge.register(executable: "/a/MemoryNotes", support: support)
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == written)

    BrowserBridge.register(executable: "/b/MemoryNotes", support: support)  // the app moved
    #expect(try Data(contentsOf: file) == BrowserBridge.manifest(executable: "/b/MemoryNotes"))

    // Firefox: its profiles folder says it's installed; its hosts live in a Mozilla folder of their own.
    let firefox = support.appendingPathComponent("Mozilla/NativeMessagingHosts/com.memorynotes.host.json")
    #expect(!FileManager.default.fileExists(atPath: firefox.path))
    try FileManager.default.createDirectory(at: support.appendingPathComponent("Firefox"), withIntermediateDirectories: true)
    BrowserBridge.register(executable: "/b/MemoryNotes", support: support)
    #expect(try Data(contentsOf: firefox) == BrowserBridge.manifest(executable: "/b/MemoryNotes", firefox: true))
}
