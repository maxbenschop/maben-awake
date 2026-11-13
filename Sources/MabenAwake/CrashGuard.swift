import AppKit

/// Rolls back an update that keeps crashing.
///
/// Updates install by themselves, and launchd restarts a crashed Maben Awake
/// within seconds. A release that crashes right after starting would therefore
/// crash on every Mac, over and over, and never get as far as installing the
/// fix. So the updater keeps the copy it replaces (`backup`), and when this
/// version has started `CrashLoop.limit` times within a few minutes without
/// quitting cleanly or running for a minute, it puts that copy back and
/// restarts as the previous version. The updater then skips the version that
/// was rolled back until a newer one comes out.
@MainActor
enum CrashGuard {
    nonisolated static let backup = LeaseStore.directory.deletingLastPathComponent()
        .appendingPathComponent("Previous version/Maben Awake.app")
    /// A version that ran for this long started fine.
    static let stableAfter: TimeInterval = 60

    private static let defaults = UserDefaults.standard
    private static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// The version that was rolled back, which isn't installed again automatically.
    static var rolledBackVersion: String? { defaults.string(forKey: "crashGuard.rolledBack") }

    /// Call first thing at launch. May replace the app and exit.
    static func checkAtLaunch() {
        if defaults.string(forKey: "crashGuard.version") != version {
            defaults.set(version, forKey: "crashGuard.version")
            defaults.removeObject(forKey: "crashGuard.starts")
        }
        let earlier = defaults.array(forKey: "crashGuard.starts") as? [Double] ?? []
        let (starts, looping) = CrashLoop.record(start: Date().timeIntervalSince1970, after: earlier)
        defaults.set(starts, forKey: "crashGuard.starts")
        guard looping else { return }
        EventLog.write("version \(version) started \(starts.count) times in \(Int(CrashLoop.window / 60)) minutes without running properly")
        rollBack()
    }

    /// The app is running fine: earlier starts no longer count.
    static func markStable() { defaults.removeObject(forKey: "crashGuard.starts") }

    /// Quitting (from the menu, for an update, or SIGTERM) isn't a crash.
    static func cleanExit() { defaults.removeObject(forKey: "crashGuard.starts") }

    // MARK: Backup

    /// Copies the running app aside before an update replaces it.
    nonisolated static func keepBackup(of app: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: backup)
        if Updater.run("/usr/bin/ditto", [app.path, backup.path]) != 0 { try? fm.removeItem(at: backup) }
    }

    nonisolated static func version(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    /// Puts the backup in place of the running app and restarts as it.
    private static func rollBack() {
        let current = Bundle.main.bundleURL
        guard let previous = version(of: backup), Updater.isNewer(version, than: previous) else {
            EventLog.write("no earlier version to go back to")
            return
        }
        do {
            try Updater.replace(current, with: backup, askForPassword: false)
        } catch {
            EventLog.write("could not go back to version \(previous): \((error as? Updater.Failure)?.message ?? "\(error)")")
            return
        }
        defaults.set(version, forKey: "crashGuard.rolledBack")
        defaults.removeObject(forKey: "crashGuard.starts")
        EventLog.write("went back to version \(previous); version \(version) won't be installed automatically again")
        // launchd starts the agent again after a non-zero exit, now with the old app.
        if Instance.launchedByLaunchd { exit(3) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", current.path]
        try? p.run()
        exit(0)
    }
}
