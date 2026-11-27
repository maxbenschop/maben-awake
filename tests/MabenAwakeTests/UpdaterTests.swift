import XCTest
@testable import MabenAwake

final class UpdaterTests: XCTestCase {
    private let fm = FileManager.default
    private var dir: URL!

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("maben-awake-updater-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: dir)
    }

    /// An unsigned stand-in for the app: a folder with a version in its Info.plist.
    @discardableResult
    private func makeApp(_ path: String, version: String) throws -> URL {
        let app = dir.appendingPathComponent(path)
        try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try NSDictionary(dictionary: ["CFBundleShortVersionString": version]).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    private func names(in folder: URL) throws -> [String] { try fm.contentsOfDirectory(atPath: folder.path).sorted() }

    // MARK: Versions and the feed

    func testVersionsCompareAsNumbers() {
        XCTAssertTrue(Updater.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(Updater.isNewer("1.4.1", than: "1.4"))
        XCTAssertFalse(Updater.isNewer("1.4", than: "1.4.0"))
        XCTAssertFalse(Updater.isNewer("1.6", than: "1.7"))
    }

    private let download = "https://github.com/maxbenschop/maben-awake/releases/download/v1.7/Maben-Awake.zip"
    private func feed(zip: String, page: String = "https://github.com/maxbenschop/maben-awake/releases/tag/v1.7", prerelease: Bool = false, asset: String = "Maben-Awake.zip") -> Data {
        let object: [String: Any] = ["tag_name": "v1.7", "draft": false, "prerelease": prerelease, "html_url": page, "body": "- Fix",
                                     "assets": [["name": "Maben-Awake.dmg", "browser_download_url": "https://github.com/maxbenschop/maben-awake/releases/download/v1.7/Maben-Awake.dmg"],
                                                ["name": asset, "browser_download_url": zip]]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testParsesTheLatestRelease() throws {
        let release = try XCTUnwrap(Updater.parse(feed(zip: download)))
        XCTAssertEqual(release.version, "1.7")
        XCTAssertEqual(release.zip.absoluteString, download)
        XCTAssertEqual(release.page.absoluteString, "https://github.com/maxbenschop/maben-awake/releases/tag/v1.7")
        XCTAssertNil(Updater.parse(feed(zip: download, prerelease: true)))
        XCTAssertNil(Updater.parse(feed(zip: download, asset: "Other.zip")))
    }

    func testOnlyDownloadsThisRepositorysReleaseFromGitHub() {
        for zip in ["http://github.com/maxbenschop/maben-awake/releases/download/v1.7/Maben-Awake.zip",
                    "https://example.com/maxbenschop/maben-awake/releases/download/v1.7/Maben-Awake.zip",
                    "https://github.com.example.com/maxbenschop/maben-awake/releases/download/v1.7/Maben-Awake.zip",
                    "https://github.com@example.com/maxbenschop/maben-awake/releases/download/v1.7/Maben-Awake.zip",
                    "https://github.com:8443/maxbenschop/maben-awake/releases/download/v1.7/Maben-Awake.zip",
                    "https://github.com/someone/else/releases/download/v1.7/Maben-Awake.zip",
                    "https://github.com/maxbenschop/maben-awake/releases/download/../../../../someone/else/releases/download/v1/Maben-Awake.zip",
                    "https://github.com/maxbenschop/maben-awake/releases/download/%2e%2e/%2e%2e/x/Maben-Awake.zip",
                    "https://github.com/maxbenschop/maben-awake/archive/Maben-Awake.zip",
                    "file:///tmp/Maben-Awake.zip"] {
            XCTAssertNil(Updater.parse(feed(zip: zip)), zip)
        }
    }

    func testOnlyOpensAReleasePageOnGitHub() throws {
        for page in ["http://github.com/maxbenschop/maben-awake/releases/tag/v1.7", "https://example.com/phish", "file:///Applications/Calculator.app", "x-apple.systempreferences:"] {
            let release = try XCTUnwrap(Updater.parse(feed(zip: download, page: page)), page)
            XCTAssertEqual(release.page.absoluteString, "https://github.com/maxbenschop/maben-awake/releases", page)
        }
    }

    func testReleaseNotesOnlyLinkOverHTTPS() {
        let notes = "- [Docs](https://awake.maben.gg/changelog) [plain](http://example.com) [file](file:///etc/passwd) [prefs](x-apple.systempreferences:com.apple.preference.security)"
        let text = Updater.notesText(notes)
        XCTAssertEqual(text.runs.compactMap(\.link).map(\.absoluteString), ["https://awake.maben.gg/changelog"])
        XCTAssertEqual(String(text.characters), "- Docs plain file prefs", "a link that isn't https stays as plain text")
    }

    // MARK: What an update must be

    func testRequirementAsksForOurDeveloperIDAndNotarization() {
        XCTAssertEqual(Updater.requirement(identifiers: ["gg.maben.one", "gg.maben.two"]),
                       "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
                       + " and certificate leaf[subject.OU] = \"NJTYRVLSA8\" and (identifier \"gg.maben.one\" or identifier \"gg.maben.two\") and notarized")
        // The app's ID today and the one it is moving to are both accepted.
        XCTAssertTrue(Updater.acceptedIdentifiers.contains(Legacy.bundleID) && Updater.acceptedIdentifiers.contains(Legacy.nextBundleID))
    }

    func testAnUnsignedAppIsNotAnUpdate() throws {
        let app = try makeApp("Maben Awake.app", version: "1.7")
        XCTAssertThrowsError(try Updater.verify(app, expectedVersion: "1.7"))
    }

    /// The release that is installed on this Mac, if any, is what a real update looks like.
    private func installedRelease() throws -> URL {
        let app = URL(fileURLWithPath: "/Applications/Maben Awake.app")
        guard CodeSignature.satisfies(app, Updater.requirement()) else { throw XCTSkip("no notarized Maben Awake in /Applications") }
        return app
    }

    func testANotarizedReleasePassesAndOnlyAsItsOwnVersion() throws {
        let app = try installedRelease()
        let version = try XCTUnwrap(CrashGuard.version(of: app))
        XCTAssertNoThrow(try Updater.verify(app, expectedVersion: version))
        XCTAssertThrowsError(try Updater.verify(app, expectedVersion: version + ".1"))
    }

    func testAReleaseThatWasChangedIsNotAnUpdate() throws {
        let copy = dir.appendingPathComponent("Maben Awake.app")
        try fm.copyItem(at: try installedRelease(), to: copy)
        let version = try XCTUnwrap(CrashGuard.version(of: copy))
        XCTAssertNoThrow(try Updater.verify(copy, expectedVersion: version))
        let script = copy.appendingPathComponent("Contents/Resources/install-failsafe.sh")
        try (String(contentsOf: script, encoding: .utf8) + "\n# changed\n").write(to: script, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Updater.verify(copy, expectedVersion: version))
    }

    // MARK: Swapping the app in a writable folder

    /// Swapping leaves the new app in place and nothing beside it (no copy in
    /// the Trash, no hidden leftover), and what was checked is the copy that went in.
    func testSwapPutsTheCheckedCopyInPlace() throws {
        let target = try makeApp("Apps/Maben Awake.app", version: "1.6"), new = try makeApp("New/Maben Awake.app", version: "1.7")
        var checked: [URL] = []
        try Updater.replace(target, with: new, version: "1.7", askForPassword: false) { checked.append($0) }
        XCTAssertEqual(checked.map(\.lastPathComponent), [".Maben Awake.update.app"])
        XCTAssertEqual(checked.first?.deletingLastPathComponent().path, target.deletingLastPathComponent().path, "checked next to the app, not where it was downloaded")
        XCTAssertEqual(CrashGuard.version(of: target), "1.7")
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["Maben Awake.app"])
        XCTAssertEqual(CrashGuard.version(of: new), "1.7", "the source is copied, not moved")
    }

    /// The real check passes on the copy under its hidden name next to the app.
    func testSwapInstallsARealReleaseCheckedWhereItLands() throws {
        let release = try installedRelease()
        let version = try XCTUnwrap(CrashGuard.version(of: release))
        let target = try makeApp("Apps/Maben Awake.app", version: "0.1")
        try Updater.replace(target, with: release, version: version, askForPassword: false) { try Updater.verify($0, expectedVersion: version) }
        XCTAssertEqual(CrashGuard.version(of: target), version)
        XCTAssertTrue(CodeSignature.satisfies(target, Updater.requirement()))
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["Maben Awake.app"])
    }

    func testSwapLeavesTheAppAloneWhenTheCopyFailsTheCheck() throws {
        let target = try makeApp("Apps/Maben Awake.app", version: "1.6"), new = try makeApp("New/Maben Awake.app", version: "1.7")
        XCTAssertThrowsError(try Updater.swap(target, with: new, check: { _ in throw Updater.Failure("not ours") })) {
            XCTAssertEqual(($0 as? Updater.Failure)?.message, "not ours")
        }
        XCTAssertEqual(CrashGuard.version(of: target), "1.6")
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["Maben Awake.app"], "the copy that failed is removed")
    }

    func testSwapPutsTheOldAppBackWhenTheNewOneCantMoveIn() throws {
        let target = try makeApp("Apps/Maben Awake.app", version: "1.6"), new = try makeApp("New/Maben Awake.app", version: "1.7")
        var moves = 0
        XCTAssertThrowsError(try Updater.swap(target, with: new, check: { _ in }, move: { from, to in
            moves += 1
            if moves == 2 { throw CocoaError(.fileWriteNoPermission) }   // the new app moving into place
            try FileManager.default.moveItem(at: from, to: to)
        }))
        XCTAssertEqual(moves, 3, "out, in (fails), back")
        XCTAssertEqual(CrashGuard.version(of: target), "1.6")
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["Maben Awake.app"])
    }

    func testSwapLeavesTheAppAloneWhenItCantBeMovedAside() throws {
        let target = try makeApp("Apps/Maben Awake.app", version: "1.6"), new = try makeApp("New/Maben Awake.app", version: "1.7")
        XCTAssertThrowsError(try Updater.swap(target, with: new, check: { _ in }, move: { _, _ in throw CocoaError(.fileWriteNoPermission) }))
        XCTAssertEqual(CrashGuard.version(of: target), "1.6")
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["Maben Awake.app"])
    }

    func testSwapReplacesWhatAnEarlierSwapLeftBehind() throws {
        let target = try makeApp("Apps/Maben Awake.app", version: "1.6"), new = try makeApp("New/Maben Awake.app", version: "1.7")
        try makeApp("Apps/.Maben Awake.update.app", version: "0.1")
        try makeApp("Apps/.Maben Awake.old.app", version: "0.2")
        try Updater.swap(target, with: new, check: { XCTAssertEqual(CrashGuard.version(of: $0), "1.7") })
        XCTAssertEqual(CrashGuard.version(of: target), "1.7")
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["Maben Awake.app"])
    }

    func testLeftoversOfACutShortSwapAreRemovedAtLaunch() throws {
        let target = try makeApp("Apps/Maben Awake.app", version: "1.7")
        try makeApp("Apps/.Maben Awake.update.app", version: "1.8")
        try makeApp("Apps/.Maben Awake.old.app", version: "1.6")
        try makeApp("Apps/Other.app", version: "1")
        Updater.removeLeftovers(beside: target)
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["Maben Awake.app", "Other.app"])
    }

    func testReplaceWithoutPasswordFailsOnAReadOnlyFolder() throws {
        let target = try makeApp("Locked/Maben Awake.app", version: "1.6"), new = try makeApp("New/Maben Awake.app", version: "1.7")
        let folder = target.deletingLastPathComponent()
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        XCTAssertThrowsError(try Updater.replace(target, with: new, version: "1.7", askForPassword: false) { _ in })
        XCTAssertEqual(CrashGuard.version(of: target), "1.6", "the running app is left alone")
    }

    // MARK: Going back to the kept copy

    func testAKeptCopyThatIsNotOursNeverComesBack() throws {
        let target = try makeApp("Apps/Maben Awake.app", version: "1.7"), kept = try makeApp("Previous version/Maben Awake.app", version: "1.6")
        XCTAssertThrowsError(try CrashGuard.check(kept, isEarlierThan: "1.7"))
        XCTAssertThrowsError(try Updater.replace(target, with: kept, version: "1.6", askForPassword: false) { try CrashGuard.check($0, isEarlierThan: "1.7") })
        XCTAssertEqual(CrashGuard.version(of: target), "1.7")
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["Maben Awake.app"])
    }

    func testAKeptCopyMustBeAnEarlierVersion() throws {
        let app = try installedRelease()
        let version = try XCTUnwrap(CrashGuard.version(of: app))
        XCTAssertNoThrow(try CrashGuard.check(app, isEarlierThan: version + ".1"))
        XCTAssertThrowsError(try CrashGuard.check(app, isEarlierThan: version))
        XCTAssertThrowsError(try CrashGuard.check(app, isEarlierThan: "0.9"))
    }

    // MARK: Installing as root

    func testRootInstallCommandCopiesChecksThenSwaps() {
        let command = Updater.rootInstallCommand(newApp: "/tmp/Update/Maben Awake.app", target: "/Applications/Maben Awake.app",
                                                 requirement: Updater.requirement(identifiers: ["gg.maben.awake"]), version: "1.8", token: "TOKEN")
        XCTAssertEqual(command, """
        T='/Applications/Maben Awake.app'
        D='/Applications/.Maben Awake.update.TOKEN'
        S="$D/Maben Awake.app"
        fail() { /bin/rm -rf "$D"; exit 1; }
        /bin/mkdir -m 700 "$D" || exit 1
        /usr/bin/ditto '/tmp/Update/Maben Awake.app' "$S" || fail
        /usr/sbin/chown -R "$(/usr/bin/stat -f %u:%g "$T")" "$S" || fail
        /bin/chmod -R ug-s "$S" || fail
        /usr/bin/codesign --verify --deep --strict -R='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "NJTYRVLSA8" and (identifier "gg.maben.awake") and notarized' "$S" || fail
        /usr/sbin/spctl --assess --type execute "$S" || fail
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$S/Contents/Info.plist")" = '1.8' ] || fail
        /bin/mv "$T" "$D/old.app" || fail
        /bin/mv "$S" "$T" || { /bin/mv "$D/old.app" "$T" || exit 1; fail; }
        /bin/rm -rf "$D"
        exit 0
        """)
    }

    func testRootInstallCommandQuotesEverythingItIsGiven() {
        let command = Updater.rootInstallCommand(newApp: "/tmp/it's $(id) `id` \"x\"/New.app", target: "/Apps/O'Brien; id/Maben Awake.app",
                                                 requirement: "identifier \"a\" and 'b'", version: "1'; id; '", token: "t'; id")
        XCTAssertTrue(command.contains(#"/usr/bin/ditto '/tmp/it'\''s $(id) `id` "x"/New.app' "$S""#))
        XCTAssertTrue(command.contains(#"T='/Apps/O'\''Brien; id/Maben Awake.app'"#))
        XCTAssertTrue(command.contains(#"D='/Apps/O'\''Brien; id/.Maben Awake.update.t'\''; id'"#))
        XCTAssertTrue(command.contains(#"-R='identifier "a" and '\''b'\''' "$S""#))
        XCTAssertTrue(command.contains(#"= '1'\''; id; '\''' ]"#))
    }

    private func sh(_ command: String) -> Int32 { Updater.run("/bin/sh", ["-c", command]) }

    /// The command itself, run without root in a folder of our own: an app that
    /// isn't ours never gets in, and nothing is left behind.
    func testRootInstallCommandLeavesTheAppAloneWhenTheCopyIsNotOurs() throws {
        let target = try makeApp("Apps/Maben Awake.app", version: "1.6"), new = try makeApp("New/Maben Awake.app", version: "1.7")
        let command = Updater.rootInstallCommand(newApp: new.path, target: target.path, requirement: Updater.requirement(), version: "1.7", token: "T1")
        XCTAssertNotEqual(sh(command), 0)
        XCTAssertEqual(CrashGuard.version(of: target), "1.6")
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["Maben Awake.app"])
    }

    func testRootInstallCommandStopsWhenItsFolderAlreadyExists() throws {
        let target = try makeApp("Apps/Maben Awake.app", version: "1.6"), new = try makeApp("New/Maben Awake.app", version: "1.7")
        let planted = target.deletingLastPathComponent().appendingPathComponent(".Maben Awake.update.T2")
        try fm.createDirectory(at: planted, withIntermediateDirectories: true)
        let command = Updater.rootInstallCommand(newApp: new.path, target: target.path, requirement: Updater.requirement(), version: "1.7", token: "T2")
        XCTAssertNotEqual(sh(command), 0)
        XCTAssertEqual(CrashGuard.version(of: target), "1.6")
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), [".Maben Awake.update.T2", "Maben Awake.app"], "a folder that was already there is not used and not removed")
    }

    /// The whole command with a real release, as far as it goes without root: checked, swapped, cleaned up.
    func testRootInstallCommandInstallsARealRelease() throws {
        let release = try installedRelease()
        let version = try XCTUnwrap(CrashGuard.version(of: release))
        let target = try makeApp("Apps/Maben Awake.app", version: "0.1")
        let folder = target.deletingLastPathComponent()

        let wrong = Updater.rootInstallCommand(newApp: release.path, target: target.path, requirement: Updater.requirement(), version: version + ".1", token: "T3")
        XCTAssertNotEqual(sh(wrong), 0, "the right app under the wrong version")
        XCTAssertEqual(CrashGuard.version(of: target), "0.1")
        XCTAssertEqual(try names(in: folder), ["Maben Awake.app"])

        let right = Updater.rootInstallCommand(newApp: release.path, target: target.path, requirement: Updater.requirement(), version: version, token: "T4")
        XCTAssertEqual(sh(right), 0)
        XCTAssertEqual(CrashGuard.version(of: target), version)
        XCTAssertTrue(CodeSignature.satisfies(target, Updater.requirement()))
        XCTAssertEqual(try names(in: folder), ["Maben Awake.app"])
    }
}
