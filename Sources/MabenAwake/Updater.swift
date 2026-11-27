import AppKit
import Combine

/// Updates from GitHub Releases (github.com/maxbenschop/maben-awake).
///
/// How it works:
/// 1. Check: GET the repository's latest release from the GitHub API (drafts and
///    pre-releases are never "latest"). Its tag `vX.Y.Z` is the version and its
///    text is shown as the release notes. Once at start, then every 6 hours, after
///    waking if the last check is over 6 hours old, or when you press Check now. This is the only network request the app makes.
/// 2. Download `Maben-Awake.zip` from that release to a temporary folder.
/// 3. Verify before touching anything: the app inside must be signed with the
///    Developer ID of team NJTYRVLSA8 with this bundle ID, notarized by Apple
///    (Gatekeeper accepts it), and newer than the running version.
/// 4. Install: keep a copy of the running app (`CrashGuard.backup`), copy the new
///    app next to the old one, verify that copy again (it is the one that goes
///    in), and swap the two. Only if the app folder isn't writable does it ask
///    for an administrator password, and then root makes its own copy and
///    checks that. Then wake every frozen app, restore sleep and brightness,
///    and restart. launchd starts the new version within seconds. If it keeps
///    crashing, `CrashGuard` puts the kept copy back.
///
/// Automatic installs only happen while the lid is open and no agent is working,
/// so an update never interrupts a job.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate(checked: Date)
        case available(Release)
        case downloading(Release, progress: Double)
        case installing(Release)
        case failed(String)
    }

    struct Release: Equatable {
        let version: String
        let notes: String
        let zip: URL
        let page: URL
    }

    @Published private(set) var state: State = .idle
    @Published var autoCheck: Bool { didSet { defaults.set(autoCheck, forKey: "updates.autoCheck"); schedule() } }
    @Published var autoInstall: Bool { didSet { defaults.set(autoInstall, forKey: "updates.autoInstall") } }

    nonisolated static let repository = "maxbenschop/maben-awake"
    nonisolated static let teamID = "NJTYRVLSA8"
    nonisolated static let feed = URL(string: "https://api.github.com/repos/maxbenschop/maben-awake/releases/latest")!
    nonisolated static let assetName = "Maben-Awake.zip"

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    /// When GitHub last answered. The timer doesn't run while the Mac sleeps, so a Mac that
    /// sleeps most of the day checks again when it wakes instead of waiting another 6 hours.
    private var lastCheck: Date?
    private var wakeObserver: NSObjectProtocol?
    private var downloadObservation: NSKeyValueObservation?

    /// Set by `--snapshot`, whose debug build has no Info.plist.
    var versionOverride: String?
    var currentVersion: String { versionOverride ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    var available: Release? {
        switch state {
        case .available(let r), .downloading(let r, _), .installing(let r): r
        default: nil
        }
    }

    /// Updates only install over a copy in an Applications folder (not a dev build or a translocated download).
    var canInstall: Bool { Integration.isInApplications && !Bundle.main.bundlePath.contains("/AppTranslocation/") }

    private init() {
        autoCheck = defaults.object(forKey: "updates.autoCheck") as? Bool ?? true
        autoInstall = defaults.object(forKey: "updates.autoInstall") as? Bool ?? true
    }

    /// Call once at launch.
    func start() {
        if canInstall { Self.removeLeftovers(beside: Bundle.main.bundleURL) }
        schedule()
        if autoCheck {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check(userInitiated: false) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAfterWake() }
        }
    }

    /// After waking, give the network half a minute, then check if the last answer is over 6 hours old.
    private func checkAfterWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.autoCheck else { return }
            if let lastCheck = self.lastCheck, Date().timeIntervalSince(lastCheck) < 6 * 3600 { return }
            self.check(userInitiated: false)
        }
    }

    private func schedule() {
        timer?.invalidate()
        guard autoCheck else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(userInitiated: false) }
        }
    }

    // MARK: Check

    func check(userInitiated: Bool) {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        var request = URLRequest(url: Self.feed, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MabenAwake/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = data.flatMap { Self.parse($0) }
            Task { @MainActor in
                if let error {
                    self.fail(userInitiated ? "Couldn't reach GitHub: \(error.localizedDescription)" : nil)
                } else if status != 200 || release == nil {
                    self.fail(userInitiated ? "GitHub didn't return a release (HTTP \(status))." : nil)
                } else if let release, Self.isNewer(release.version, than: self.currentVersion) {
                    self.lastCheck = Date()
                    self.state = .available(release)
                    EventLog.write("update available: \(release.version)")
                    if self.autoInstall { self.installWhenQuiet() }
                } else {
                    self.lastCheck = Date()
                    self.state = .upToDate(checked: Date())
                }
            }
        }.resume()
    }

    private func fail(_ message: String?) {
        if let message { state = .failed(message); EventLog.write("update: \(message)") } else { state = .idle }
    }

    nonisolated static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
              let zip = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
              isOnGitHub(zip), zip.path.hasPrefix("/\(repository)/releases/download/")
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        // The page is opened in the browser, so it is this repository's own releases page unless GitHub names another of its pages.
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)).flatMap { isOnGitHub($0) ? $0 : nil } ?? releasesPage
        return Release(version: version, notes: (json["body"] as? String) ?? "", zip: zip, page: page)
    }

    nonisolated static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!

    /// An `https://github.com/…` address. What the feed says is only data: the app
    /// downloads from and opens nothing else, whatever the answer contains.
    nonisolated static func isOnGitHub(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com"
            && url.user == nil && (url.port ?? 443) == 443 && !url.pathComponents.contains("..")
    }

    /// The release notes for display. They come from the network, so a link in
    /// them only works when it is `https`; any other link is shown as plain text.
    nonisolated static func notesText(_ notes: String) -> AttributedString {
        guard var text = try? AttributedString(markdown: notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(notes) }
        for run in text.runs {
            if let link = run.link, link.scheme?.lowercased() != "https" { text[run.range].link = nil }
        }
        return text
    }

    /// Numeric comparison of dotted versions: 1.10 > 1.9, 1.4.1 > 1.4.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Install

    /// Automatic install: wait until the lid is open and no agent is working.
    private func installWhenQuiet() {
        guard canInstall else { return }
        // A version that was rolled back because it kept crashing waits for a newer one.
        if let release = available, release.version == CrashGuard.rolledBackVersion {
            EventLog.write("update: not installing \(release.version) automatically, it was rolled back")
            return
        }
        let model = Model.shared
        if !model.away && !model.aiWorking {
            install()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
                guard let self, case .available = self.state, self.autoInstall else { return }
                self.installWhenQuiet()
            }
        }
    }

    func install() {
        guard let release = available, canInstall else { return }
        if case .downloading = state { return }
        if case .installing = state { return }
        state = .downloading(release, progress: 0)
        EventLog.write("update: downloading \(release.version)")
        let task = URLSession.shared.downloadTask(with: release.zip) { location, response, error in
            // The temporary file is deleted when this returns, so move it first.
            var kept: URL?
            if let location {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("MabenAwake-\(UUID().uuidString).zip")
                if (try? FileManager.default.moveItem(at: location, to: dest)) != nil { kept = dest }
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in
                guard let kept, error == nil, status == 200 else {
                    self.state = .failed("The download failed\(error.map { ": \($0.localizedDescription)" } ?? " (HTTP \(status)).")")
                    return
                }
                self.state = .installing(release)
                Task.detached { await self.finish(zip: kept, release: release) }
            }
        }
        downloadObservation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in
                if case .downloading(let r, _) = self.state { self.state = .downloading(r, progress: value) }
            }
        }
        task.resume()
    }

    /// Unpacks, verifies and swaps the app. Runs off the main thread.
    private nonisolated func finish(zip: URL, release: Release) async {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("MabenAwakeUpdate-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: zip) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) == 0 else { throw Failure("Couldn't unpack the update.") }
            guard let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" })
            else { throw Failure("The update doesn't contain an app.") }
            // Checked here first, so a bad download never gets as far as a password prompt.
            try Self.verify(newApp, expectedVersion: release.version)
            let target = await MainActor.run { Bundle.main.bundleURL }
            // Kept so a release that keeps crashing can be rolled back (CrashGuard).
            CrashGuard.keepBackup(of: target)
            try Self.replace(target, with: newApp, version: release.version) { try Self.verify($0, expectedVersion: release.version) }
            try? fm.removeItem(at: work)
            await MainActor.run { self.relaunch(version: release.version) }
        } catch {
            try? fm.removeItem(at: work)
            let message = (error as? Failure)?.message ?? error.localizedDescription
            await MainActor.run {
                self.state = .failed(message)
                EventLog.write("update: \(message)")
            }
        }
    }

    struct Failure: Error { let message: String; init(_ m: String) { message = m } }

    /// Bundle IDs an update may have: this copy's, and the one the app is moving to (see `Legacy`).
    nonisolated static var acceptedIdentifiers: [String] {
        var ids = [Bundle.main.bundleIdentifier ?? Legacy.bundleID, Legacy.bundleID, Legacy.nextBundleID]
        ids = ids.enumerated().filter { ids.firstIndex(of: $0.element) == $0.offset }.map(\.element)
        return ids
    }

    /// What an update or an earlier version must be, as a code requirement: signed
    /// with a Developer ID (not a development or App Store certificate) of our
    /// team, under one of our bundle IDs, and notarized by Apple, whatever this
    /// Mac's Gatekeeper setting is. The one text for the check in this process
    /// and for the check root runs on its own copy.
    nonisolated static func requirement(identifiers: [String] = acceptedIdentifiers) -> String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
            + " and \(CodeSignature.identifiers(identifiers)) and notarized"
    }

    /// The app must be ours, notarized, and the version we expect.
    nonisolated static func verify(_ app: URL, expectedVersion: String) throws {
        guard CodeSignature.satisfies(app, requirement()) else {
            throw Failure("The update isn't signed by Maben and notarized by Apple. It was not installed.")
        }
        // Gatekeeper's own answer as well: it also knows what Apple has revoked.
        guard run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) == 0 else {
            throw Failure("The update isn't notarized by Apple. It was not installed.")
        }
        guard CrashGuard.version(of: app) == expectedVersion else {
            throw Failure("The update's version doesn't match the release.")
        }
    }

    /// Hidden names beside the app while it is swapped: the copy going in, and the app going out.
    nonisolated static let stagedName = ".Maben Awake.update.app"
    nonisolated static let oldName = ".Maben Awake.old.app"

    /// Puts `newApp` (which has `version`) in place of `target`. `check` runs on
    /// the copy that goes in and throws if it may not. The old app is kept in
    /// Application Support (one version only, see `CrashGuard`), not in the
    /// Trash, so updates don't pile up there.
    nonisolated static func replace(_ target: URL, with newApp: URL, version: String, askForPassword: Bool = true,
                                    check: (URL) throws -> Void) throws {
        let fm = FileManager.default
        if fm.isWritableFile(atPath: target.deletingLastPathComponent().path) && fm.isWritableFile(atPath: target.path) {
            try swap(target, with: newApp, check: check)
        } else if !askForPassword {
            throw Failure("The app folder isn't writable without an administrator password.")
        } else {
            // Installed by an administrator: ask for the password once. Root copies, checks and swaps (`rootInstallCommand`).
            let command = rootInstallCommand(newApp: newApp.path, target: target.path, requirement: requirement(),
                                             version: version, token: UUID().uuidString)
            switch AdminShell.runAndWait(command, prompt: "Maben Awake wants to install an update.") {
            case .done: break
            case .cancelled: throw Failure("The update was not installed (no administrator password).")
            case .failed: throw Failure("The update was not installed: it couldn't be copied or didn't pass the checks.")
            }
        }
    }

    /// Swaps the app in a folder we can write to. The new app is first copied
    /// next to the old one and `check` runs on that copy: what was checked is
    /// what goes in, whatever happens to `newApp` meanwhile. Then two renames,
    /// and if the second fails the old app goes back, so the app is never
    /// missing after a failure. (`move` is only replaced by the tests.)
    nonisolated static func swap(_ target: URL, with newApp: URL, check: (URL) throws -> Void,
                                 move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        let fm = FileManager.default
        let folder = target.deletingLastPathComponent()
        let staged = folder.appendingPathComponent(stagedName), old = folder.appendingPathComponent(oldName)
        func failure(_ error: Error) -> Failure {
            try? fm.removeItem(at: staged)
            return (error as? Failure) ?? Failure("Couldn't install the update: \(error.localizedDescription)")
        }
        try? fm.removeItem(at: staged)   // left by a swap that was cut short
        do {
            try fm.copyItem(at: newApp, to: staged)
            try check(staged)
        } catch {
            throw failure(error)
        }
        try? fm.removeItem(at: old)
        do { try move(target, old) } catch { throw failure(error) }
        do {
            try move(staged, target)
        } catch {
            try? move(old, target)   // put the old one back
            throw failure(error)
        }
        try? fm.removeItem(at: old)
    }

    /// A swap that was cut short (power loss, force quit) leaves a hidden copy beside the app.
    nonisolated static func removeLeftovers(beside target: URL) {
        for name in [stagedName, oldName] {
            try? FileManager.default.removeItem(at: target.deletingLastPathComponent().appendingPathComponent(name))
        }
    }

    /// The shell command root runs to install an update where the app folder
    /// isn't writable. What this process checked proves nothing to root: the
    /// download is in a folder the user's other processes can write to. So root
    /// copies it into a folder of its own next to the app (mode 700 from the
    /// moment it exists, so nobody else can reach inside), checks that copy
    /// (signature, Gatekeeper, version) and swaps it in with two renames. Any
    /// failure removes the folder and leaves the app as it was.
    /// `token` makes the folder's name; it must be new every time.
    nonisolated static func rootInstallCommand(newApp: String, target: String, requirement: String, version: String, token: String) -> String {
        let q = AdminShell.quote
        let folder = (target as NSString).deletingLastPathComponent
        return [
            "T=\(q(target))",
            "D=\(q(folder + "/.Maben Awake.update." + token))",
            #"S="$D/Maben Awake.app""#,
            #"fail() { /bin/rm -rf "$D"; exit 1; }"#,
            // Not `fail`: a folder that was already there isn't ours to remove.
            #"/bin/mkdir -m 700 "$D" || exit 1"#,
            #"/usr/bin/ditto \#(q(newApp)) "$S" || fail"#,
            // The new app belongs to whoever owned the old one, and brings no set-user-ID bit of its own making.
            #"/usr/sbin/chown -R "$(/usr/bin/stat -f %u:%g "$T")" "$S" || fail"#,
            #"/bin/chmod -R ug-s "$S" || fail"#,
            #"/usr/bin/codesign --verify --deep --strict -R=\#(q(requirement)) "$S" || fail"#,
            #"/usr/sbin/spctl --assess --type execute "$S" || fail"#,
            #"[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$S/Contents/Info.plist")" = \#(q(version)) ] || fail"#,
            #"/bin/mv "$T" "$D/old.app" || fail"#,
            // If the old app can't go back either, it stays in the folder: never `fail` with the only copy in there.
            #"/bin/mv "$S" "$T" || { /bin/mv "$D/old.app" "$T" || exit 1; fail; }"#,
            #"/bin/rm -rf "$D""#,
            "exit 0",
        ].joined(separator: "\n")
    }

    /// Restores everything, then restarts as the new version.
    private func relaunch(version: String) {
        EventLog.write("update: installed \(version), restarting")
        Model.shared.shutdown()
        if Instance.isEnabled {
            // launchd restarts the agent after a non-zero exit, with the new executable.
            exit(3)
        }
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        exit(0)
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
