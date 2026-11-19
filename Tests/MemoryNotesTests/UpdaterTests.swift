import Foundation
import Testing

/// Sparkle's settings in the shipped Info.plist. The feed URL is fixed: the maintainer's publish script writes it (D75).
@Test func infoPlistHasTheHTTPSFeedAndAPublicKey() throws {
    let url = URL(fileURLWithPath: #filePath).appendingPathComponent("../../../Info.plist").standardized
    let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    #expect(plist["SUFeedURL"] as? String == "https://noteanywhere.app/appcast.xml")
    #expect((plist["SUPublicEDKey"] as? String)?.isEmpty == false)
}
