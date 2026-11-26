import XCTest
@testable import NotificationTicker

final class AppUpdaterTests: XCTestCase {
    func testComparesVersionsNumerically() {
        XCTAssertLessThan(AppVersion("0.2.9")!, AppVersion("0.2.10")!, "文字ではなく数で比べる")
        XCTAssertLessThan(AppVersion("0.2.14")!, AppVersion("v0.3.0")!)
        XCTAssertEqual(AppVersion("v0.2.14"), AppVersion("0.2.14"))
        XCTAssertEqual(AppVersion("1.0"), AppVersion("1.0.0"))
        XCTAssertFalse(AppVersion("0.2.14")! < AppVersion("0.2.14")!)
        XCTAssertNil(AppVersion("beta"))
        XCTAssertNil(AppVersion(""))
    }

    func testReadsLatestReleaseAndPicksDMG() throws {
        let json = """
        {"tag_name":"v0.2.15","assets":[
          {"name":"notes.txt","browser_download_url":"https://example.com/notes.txt"},
          {"name":"NotificationTicker-0.2.15.dmg","browser_download_url":"https://example.com/NotificationTicker-0.2.15.dmg"}
        ]}
        """
        let release = try JSONDecoder().decode(LatestRelease.self, from: Data(json.utf8))
        XCTAssertEqual(release.version, AppVersion("0.2.15"))
        XCTAssertEqual(release.dmg?.name, "NotificationTicker-0.2.15.dmg")
    }

    func testPretendVersionOverridesBundleVersion() {
        let defaults = UserDefaults(suiteName: "AppUpdaterTests-\(UUID().uuidString)")!
        defaults.set("0.0.1", forKey: AppUpdater.pretendVersionKey)
        XCTAssertEqual(AppUpdater(defaults: defaults).currentVersion, AppVersion("0.0.1"))
    }

    func testRejectsAppSignedBySomeoneElse() {
        // テスト実行ファイルの入れ物（xctest）は識別子も署名も配布物と違うので、入れてはいけない。
        let bundle = Bundle(for: AppUpdaterTests.self).bundleURL
        XCTAssertNotNil(AppUpdater.verify(app: bundle, expecting: AppVersion("0.2.14")!))
    }
}
