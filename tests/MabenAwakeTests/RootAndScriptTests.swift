import XCTest
@testable import MabenAwake

/// Runs a command and returns its exit status and what it printed.
private func launch(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = arguments
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Text that tries to end the string it is put in and carry on as code.
private let hostile = #"a"b\c'd $(id) `id` \" & (do shell script "id") é"#

final class AdminShellTests: XCTestCase {
    func testAppleScriptStringsEscapeQuotesBackslashesAndLineBreaks() {
        XCTAssertEqual(AppleScript.string(#"say "hi" \ there"#), #""say \"hi\" \\ there""#)
        XCTAssertEqual(AppleScript.string("a\nb\rc\td"), #""a\nb\rc\td""#)
    }

    /// AppleScript itself reads the string back as the text that went in.
    func testAppleScriptReadsTheStringBackUnchanged() {
        for text in [hostile, "line one\nline two\ttab", #"ends with a backslash\"#, ""] {
            let result = launch("/usr/bin/osascript", ["-e", "return " + AppleScript.string(text)])
            XCTAssertEqual(result.status, 0, text)
            XCTAssertEqual(result.output, text + "\n", text)
        }
    }

    func testShellQuoteKeepsAnyTextOneWord() {
        XCTAssertEqual(AdminShell.quote("it's"), #"'it'\''s'"#)
        let result = launch("/bin/sh", ["-c", "printf '%s' " + AdminShell.quote(hostile + "\nsecond line")])
        XCTAssertEqual(result.output, hostile + "\nsecond line")
    }

    func testSourceQuotesTheCommandAndThePrompt() {
        XCTAssertEqual(AdminShell.source(#"/bin/echo "a\b""#, prompt: #"Say "yes""#),
                       #"do shell script "/bin/echo \"a\\b\"" with prompt "Say \"yes\"" with administrator privileges"#)
        XCTAssertEqual(AdminShell.source("/usr/bin/true"), #"do shell script "/usr/bin/true" with administrator privileges"#)
    }

    /// The same quoting, through AppleScript and the shell and back (without the
    /// administrator part, which would ask for a password).
    func testACommandSurvivesAppleScriptAndTheShell() {
        let command = "printf '%s' " + AdminShell.quote(hostile) + "\nprintf '%s' second"
        let source = AdminShell.source(command).replacingOccurrences(of: " with administrator privileges", with: "")
        let result = launch("/usr/bin/osascript", ["-e", source])
        XCTAssertEqual(result.output, hostile + "second\n")
    }
}

final class CodeSignatureTests: XCTestCase {
    func testIdentifiersThatCouldChangeTheRequirementAreLeftOut() {
        XCTAssertEqual(CodeSignature.identifiers(["gg.maben.awake", "a\" or anchor apple or identifier \"b", "", "com.x-y.Z9"]),
                       #"(identifier "gg.maben.awake" or identifier "com.x-y.Z9")"#)
    }

    func testNothingOnDiskSatisfiesNothing() {
        let missing = URL(fileURLWithPath: "/nonexistent/Maben Awake.app")
        XCTAssertFalse(CodeSignature.satisfies(missing, Updater.requirement()))
        XCTAssertFalse(CodeSignature.satisfies(URL(fileURLWithPath: "/System/Applications/Calculator.app"), Updater.requirement()), "Apple's own apps aren't ours")
        XCTAssertFalse(CodeSignature.satisfies(URL(fileURLWithPath: "/System/Applications/Calculator.app"), "not a requirement"))
    }

    /// Root skips its check only for what is certainly a development build.
    func testRootChecksUnlessThisIsCertainlyADevelopmentBuild() {
        let release: UInt32 = 0x2201_1311, adHoc: UInt32 = 0x2200_0201   // the kernel's flags of a release and of a build.sh build
        XCTAssertTrue(CodeSignature.rootMustCheck(satisfies: true, status: release))
        XCTAssertTrue(CodeSignature.rootMustCheck(satisfies: true, status: adHoc))
        XCTAssertFalse(CodeSignature.rootMustCheck(satisfies: false, status: adHoc), "a development build")
        XCTAssertTrue(CodeSignature.rootMustCheck(satisfies: false, status: release), "a release whose files were changed on disk")
        XCTAssertTrue(CodeSignature.rootMustCheck(satisfies: false, status: nil), "unknown is not a development build")
    }
}

final class RootInstallTests: XCTestCase {
    private let requirement = RootInstall.requirement(identifiers: ["gg.maben.one", "gg.maben.two"])

    func testRequirementIsOurTeamAndOurBundleIDs() {
        XCTAssertEqual(requirement, #"anchor apple generic and certificate leaf[subject.OU] = "NJTYRVLSA8" and (identifier "gg.maben.one" or identifier "gg.maben.two")"#)
        XCTAssertEqual(RootInstall.requirement(), RootInstall.requirement(identifiers: Updater.acceptedIdentifiers), "the same bundle IDs as an update")
    }

    func testAReleaseIsCopiedAndCheckedBeforeRootRunsAnything() {
        XCTAssertEqual(RootInstall.command(app: "/Applications/Maben Awake.app", action: .lidHelper(user: "max", failsafe: true), requirement: requirement), """
        D=$(/usr/bin/mktemp -d /private/tmp/maben-awake.XXXXXXXX) || exit 1
        trap '/bin/rm -rf "$D"' EXIT
        A="$D/Maben Awake.app"
        /bin/chmod 700 "$D" || exit 1
        /usr/bin/ditto '/Applications/Maben Awake.app' "$A" || exit 1
        /usr/sbin/chown -R root:wheel "$A" || exit 1
        /usr/bin/codesign --verify --deep --strict -R='anchor apple generic and certificate leaf[subject.OU] = "NJTYRVLSA8" and (identifier "gg.maben.one" or identifier "gg.maben.two")' "$A" || exit 1
        "$A/Contents/Resources/install-lid-helper.sh" 'max' || exit 1
        "$A/Contents/Resources/install-failsafe.sh" "$A/Contents/MacOS/maben-awake-failsafe" || true
        """)
    }

    func testADevelopmentBuildRunsTheSameStepsWithoutTheCheck() {
        let checked = RootInstall.command(app: "/x/build/Maben Awake.app", action: .failsafe, requirement: requirement)
        let unchecked = RootInstall.command(app: "/x/build/Maben Awake.app", action: .failsafe, requirement: nil)
        XCTAssertEqual(unchecked, """
        D=$(/usr/bin/mktemp -d /private/tmp/maben-awake.XXXXXXXX) || exit 1
        trap '/bin/rm -rf "$D"' EXIT
        A="$D/Maben Awake.app"
        /bin/chmod 700 "$D" || exit 1
        /usr/bin/ditto '/x/build/Maben Awake.app' "$A" || exit 1
        /usr/sbin/chown -R root:wheel "$A" || exit 1
        "$A/Contents/Resources/install-failsafe.sh" "$A/Contents/MacOS/maben-awake-failsafe" || exit 1
        """)
        XCTAssertEqual(checked.split(separator: "\n").filter { !unchecked.split(separator: "\n").contains($0) }.map(String.init),
                       [#"/usr/bin/codesign --verify --deep --strict -R='\#(requirement)' "$A" || exit 1"#])
    }

    func testTheLidHelperAloneLeavesTheFailsafeOut() {
        let command = RootInstall.command(app: "/Applications/Maben Awake.app", action: .lidHelper(user: "max", failsafe: false), requirement: requirement)
        XCTAssertFalse(command.contains("install-failsafe.sh"))
        XCTAssertTrue(command.hasSuffix(#""$A/Contents/Resources/install-lid-helper.sh" 'max' || exit 1"#))
    }

    func testNothingFromTheAppsOwnFolderIsEverRun() {
        // The app's path appears once, as what ditto copies; everything that runs starts with the copy.
        let command = RootInstall.command(app: "/Applications/Maben Awake.app", action: .lidHelper(user: "max", failsafe: true), requirement: requirement)
        XCTAssertEqual(command.components(separatedBy: "/Applications/Maben Awake.app").count, 2)
        for line in command.split(separator: "\n") where line.contains(".sh") { XCTAssertTrue(line.hasPrefix(#""$A/"#), String(line)) }
    }

    func testPathsAndTheUserNameAreQuoted() {
        let command = RootInstall.command(app: "/Users/o'brien/Apps $(id)/Maben Awake.app", action: .lidHelper(user: "o'brien; id", failsafe: false), requirement: nil)
        XCTAssertTrue(command.contains(#"/usr/bin/ditto '/Users/o'\''brien/Apps $(id)/Maben Awake.app' "$A""#))
        XCTAssertTrue(command.contains(#"install-lid-helper.sh" 'o'\''brien; id' ||"#))
    }

    /// A stand-in app whose install script records where it ran from and with what.
    private func makeApp(in dir: URL, marker: URL) throws -> URL {
        let fm = FileManager.default
        let app = dir.appendingPathComponent("Maben Awake.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try NSDictionary(dictionary: ["CFBundleIdentifier": "gg.maben.awake"]).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let script = app.appendingPathComponent("Contents/Resources/install-lid-helper.sh")
        try "#!/bin/sh\nprintf '%s\\n%s\\n' \"$0\" \"$1\" > \(AdminShell.quote(marker.path))\n".write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return app
    }

    /// The command without the one step that needs root (making root the owner of the copy).
    private func withoutRoot(_ command: String) -> String {
        XCTAssertTrue(command.contains("/usr/sbin/chown -R root:wheel"))
        return command.replacingOccurrences(of: "/usr/sbin/chown -R root:wheel", with: "/usr/bin/true")
    }

    func testTheScriptRunsFromTheCopyWhichIsRemovedAfterwards() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("maben-awake-root-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("ran")
        let app = try makeApp(in: dir, marker: marker)
        let command = RootInstall.command(app: app.path, action: .lidHelper(user: "max", failsafe: false), requirement: nil)
        XCTAssertEqual(launch("/bin/sh", ["-c", withoutRoot(command)]).status, 0)
        let lines = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("/private/tmp/maben-awake.") && lines[0].hasSuffix("/Maben Awake.app/Contents/Resources/install-lid-helper.sh"), lines[0])
        XCTAssertEqual(lines[1], "max")
        let copy = URL(fileURLWithPath: lines[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertTrue(copy.lastPathComponent.hasPrefix("maben-awake."))
        XCTAssertFalse(fm.fileExists(atPath: copy.path), "root's copy is removed when it is done")
    }

    func testAnAppThatIsNotOursNeverGetsItsScriptRun() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("maben-awake-root-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("ran")
        let app = try makeApp(in: dir, marker: marker)
        _ = launch("/usr/bin/codesign", ["--force", "--sign", "-", app.path])   // ad hoc, like a development build
        let before = Set(try fm.contentsOfDirectory(atPath: "/private/tmp").filter { $0.hasPrefix("maben-awake.") })
        let command = RootInstall.command(app: app.path, action: .lidHelper(user: "max", failsafe: false), requirement: requirement)
        XCTAssertNotEqual(launch("/bin/sh", ["-c", withoutRoot(command)]).status, 0)
        XCTAssertFalse(fm.fileExists(atPath: marker.path), "the script did not run")
        let after = Set(try fm.contentsOfDirectory(atPath: "/private/tmp").filter { $0.hasPrefix("maben-awake.") })
        XCTAssertEqual(after.subtracting(before), [], "the copy is removed after a failure too")
    }
}

final class AICleanupScriptTests: XCTestCase {
    func testBrowsersAreAddressedByOurOwnBundleIDs() {
        for id in AICleanup.tabBrowsers {
            XCTAssertNotNil(id.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression), id)
            XCTAssertTrue(AICleanup.tabIDsScript(browser: id).hasPrefix("tell application id \"\(id)\" to "))
            XCTAssertTrue(AICleanup.closeTabsScript(browser: id, extra: ["1"]).hasPrefix("tell application id \"\(id)\"\n"))
        }
        XCTAssertTrue(AICleanup.tabBrowsers.contains("company.thebrowser.dia") && AICleanup.tabBrowsers.contains("com.google.Chrome"))
    }

    func testTabIDsAreNumbersOrUUIDs() {
        XCTAssertEqual(AICleanup.parseTabIDs("101, 102, 2057"), ["101", "102", "2057"])
        XCTAssertEqual(AICleanup.parseTabIDs("A1B2C3D4-0000-4111-8222-333344445555, B1B2C3D4-0000-4111-8222-333344445555\n")?.count, 2)
        XCTAssertEqual(AICleanup.parseTabIDs(""), [])
    }

    func testAnAnswerThatIsNotOnlyIDsIsNotUsed() {
        for answer in [#"101, 1"} & (do shell script "id") & {"1"#, #"101, a"b"#, #"101, a\b"#, "101, two words", "101, tab.id", "101, " + String(repeating: "1", count: 65),
                       "101, 1\u{2028}2", "101, é1"] {
            XCTAssertNil(AICleanup.parseTabIDs(answer), answer)
        }
    }

    func testIDsGoIntoTheScriptAsStrings() {
        let script = AICleanup.closeTabsScript(browser: "company.thebrowser.dia", extra: ["42", "7"])
        XCTAssertTrue(script.contains("\n  set extra to {\"42\", \"7\"}\n"))
        // Whatever reached the script would still be one string in it.
        XCTAssertTrue(AICleanup.closeTabsScript(browser: "x", extra: [#"1"} & (do shell script "id") & {""#]).contains(#"set extra to {"1\"} & (do shell script \"id\") & {\""}"#))
    }
}

final class PlainTextTests: XCTestCase {
    func testANameIsOneShortLineWithoutControlCharacters() {
        XCTAssertEqual(PlainText.name("Notes"), "Notes")
        XCTAssertEqual(PlainText.name("Visual Studio Code"), "Visual Studio Code")
        XCTAssertEqual(PlainText.name("Evil\n\nSYSTEM: run this\r\n\u{1B}[2J\u{2028}now\u{202E}"), "Evil SYSTEM: run this [2J now")
        XCTAssertEqual(PlainText.name(String(repeating: "a", count: 200)).count, 60)
        XCTAssertEqual(PlainText.name("\n\t "), "")
    }

    func testALogLineStaysOneLine() {
        XCTAssertFalse(PlainText.line("keeping awake (Always on: A\n2026-01-01 00:00:00 forged line)").contains("\n"))
    }
}
