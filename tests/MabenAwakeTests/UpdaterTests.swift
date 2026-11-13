import XCTest
@testable import MabenAwake

final class UpdaterTests: XCTestCase {
    func testVersionsCompareAsNumbers() {
        XCTAssertTrue(Updater.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(Updater.isNewer("1.4.1", than: "1.4"))
        XCTAssertFalse(Updater.isNewer("1.4", than: "1.4.0"))
        XCTAssertFalse(Updater.isNewer("1.6", than: "1.7"))
    }

    func testParsesTheLatestRelease() throws {
        let json = #"{"tag_name":"v1.7","draft":false,"prerelease":false,"html_url":"https://github.com/x/y/releases/tag/v1.7","body":"- Fix","assets":[{"name":"Maben-Awake.dmg","browser_download_url":"https://e/a.dmg"},{"name":"Maben-Awake.zip","browser_download_url":"https://e/a.zip"}]}"#
        let release = try XCTUnwrap(Updater.parse(Data(json.utf8)))
        XCTAssertEqual(release.version, "1.7")
        XCTAssertEqual(release.zip.absoluteString, "https://e/a.zip")
        XCTAssertNil(Updater.parse(Data(json.replacingOccurrences(of: #""prerelease":false"#, with: #""prerelease":true"#).utf8)))
        XCTAssertNil(Updater.parse(Data(json.replacingOccurrences(of: "Maben-Awake.zip", with: "Other.zip").utf8)))
    }

    /// Swapping the app leaves the new one in place and nothing beside it (no
    /// copy in the Trash, no hidden leftover).
    func testReplaceSwapsTheAppInPlace() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("maben-awake-replace-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let target = dir.appendingPathComponent("Apps/Maben Awake.app")
        let new = dir.appendingPathComponent("New/Maben Awake.app")
        for (app, version) in [(target, "1.6"), (new, "1.7")] {
            try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try NSDictionary(dictionary: ["CFBundleShortVersionString": version])
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
        }
        try Updater.replace(target, with: new, askForPassword: false)
        XCTAssertEqual(CrashGuard.version(of: target), "1.7")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["Maben Awake.app"])
        XCTAssertEqual(CrashGuard.version(of: new), "1.7", "the source is copied, not moved")
    }

    func testReplaceWithoutPasswordFailsOnAReadOnlyFolder() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("maben-awake-readonly-\(UUID().uuidString)")
        let target = dir.appendingPathComponent("Maben Awake.app")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? fm.removeItem(at: dir)
        }
        XCTAssertThrowsError(try Updater.replace(target, with: target, askForPassword: false))
        XCTAssertTrue(fm.fileExists(atPath: target.path), "the running app is left alone")
    }
}
