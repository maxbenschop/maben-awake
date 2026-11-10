import AppKit
import Combine
import Security

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
/// 4. Install: replace the app in place (asking for an administrator password only
///    if the app folder isn't writable), wake every frozen app and restore sleep
///    and brightness, then restart. launchd starts the new version within seconds.
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

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

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
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: (json["body"] as? String) ?? "", zip: zip, page: page)
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
            try Self.verify(newApp, expectedVersion: release.version)
            let target = await MainActor.run { Bundle.main.bundleURL }
            try Self.replace(target, with: newApp)
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

    /// The downloaded app must be ours, notarized, and the version we expect.
    nonisolated static func verify(_ app: URL, expectedVersion: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure("The update isn't a valid app.")
        }
        let ids = acceptedIdentifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        let text = "anchor apple generic and (\(ids)) and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw Failure("Couldn't check the update's signature.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw Failure("The update isn't signed by Maben. It was not installed.")
        }
        // Notarized: Gatekeeper accepts it as a downloaded app.
        guard run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) == 0 else {
            throw Failure("The update isn't notarized by Apple. It was not installed.")
        }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard (info?["CFBundleShortVersionString"] as? String) == expectedVersion else {
            throw Failure("The update's version doesn't match the release.")
        }
    }

    /// Swaps the app bundle. The old copy goes to the Trash, so it can be restored by hand.
    nonisolated static func replace(_ target: URL, with newApp: URL) throws {
        let fm = FileManager.default
        if fm.isWritableFile(atPath: target.deletingLastPathComponent().path) && fm.isWritableFile(atPath: target.path) {
            var trashed: NSURL?
            try fm.trashItem(at: target, resultingItemURL: &trashed)
            do {
                try fm.copyItem(at: newApp, to: target)
            } catch {
                if let trashed { try? fm.moveItem(at: trashed as URL, to: target) }   // put the old one back
                throw Failure("Couldn't install the update: \(error.localizedDescription)")
            }
        } else {
            // Installed by an administrator: ask for the password once.
            let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let staged = target.deletingLastPathComponent().appendingPathComponent(".Maben Awake.update.app").path
            let command = "/bin/rm -rf \(q(staged)) && /usr/bin/ditto \(q(newApp.path)) \(q(staged)) && /bin/rm -rf \(q(target.path)) && /bin/mv \(q(staged)) \(q(target.path))"
            let script = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with prompt \"Maben Awake wants to install an update.\" with administrator privileges"
            guard run("/usr/bin/osascript", ["-e", script]) == 0 else { throw Failure("The update was not installed (no administrator password).") }
        }
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
