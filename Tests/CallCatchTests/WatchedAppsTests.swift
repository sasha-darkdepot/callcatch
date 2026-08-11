import XCTest
@testable import CallCatch

final class WatchedAppsTests: XCTestCase {
    func testMatchesMainBundles() {
        XCTAssertEqual(WatchedApps.match(bundleID: "com.hnc.Discord"), .discord)
        XCTAssertEqual(WatchedApps.match(bundleID: "org.whispersystems.signal-desktop"), .signal)
        XCTAssertEqual(WatchedApps.match(bundleID: "ru.keepcoder.Telegram"), .telegram)
        XCTAssertEqual(WatchedApps.match(bundleID: "org.telegram.desktop"), .telegram)
        XCTAssertEqual(WatchedApps.match(bundleID: "net.whatsapp.WhatsApp"), .whatsapp)
    }
    func testMatchesHelperBundlesByPrefix() {
        XCTAssertEqual(WatchedApps.match(bundleID: "com.hnc.Discord.helper"), .discord)
        XCTAssertEqual(WatchedApps.match(bundleID: "org.whispersystems.signal-desktop.helper.GPU"), .signal)
    }
    func testNoFalseMatches() {
        XCTAssertNil(WatchedApps.match(bundleID: "com.apple.Safari"))
        XCTAssertNil(WatchedApps.match(bundleID: ""))
        XCTAssertNil(WatchedApps.match(bundleID: "net.whatsapp.WhatsApp2"))
    }
    func testDisplayNames() {
        XCTAssertEqual(WatchedApp.discord.displayName, "Discord")
        XCTAssertEqual(WatchedApp.telegram.displayName, "Telegram")
    }
}
