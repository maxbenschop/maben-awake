import AppKit
import ServiceManagement

/// Crash safety: Sleepwalker runs as a launchd agent with KeepAlive, so if it
/// crashes or is force-killed, launchd restarts it within seconds and the new
/// instance thaws every app the old one left frozen. Quitting from the menu
/// exits cleanly (status 0), which launchd does not restart.
///
/// This is a classic LaunchAgent in ~/Library/LaunchAgents with an absolute
/// program path. `SMAppService.agent` with a bundle-relative path fails to
/// spawn on macOS 26 ("Could not find and/or execute program").
enum Instance {
    static let agentLabel = "com.maxbenschop.sleepwalker.agent"
    private static let domain = "gui/\(getuid())"
    private static let plistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")

    static var launchedByLaunchd: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == agentLabel
    }

    /// Agent file present and loaded in launchd.
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path) && launchctl(["print", "\(domain)/\(agentLabel)"]) == 0
    }

    /// Makes sure exactly one instance runs, preferably the launchd-managed one.
    /// Call before anything else; may exit the process.
    static func ensureSingle() {
        let me = getpid()
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }

        if launchedByLaunchd {
            // A manually started copy is running: take over from it.
            for other in others { Signals.send(SIGTERM, to: other.processIdentifier) }
            let deadline = Date().addingTimeInterval(3)
            while others.contains(where: { !$0.isTerminated }) && Date() < deadline { usleep(50_000) }
            // Taking over from a copy we stopped ourselves is not a crash.
            if !others.isEmpty { UserDefaults.standard.set(false, forKey: "running") }
            return
        }
        if !others.isEmpty { exit(0) }               // already running
        if isEnabled, launchctl(["kickstart", "\(domain)/\(agentLabel)"]) == 0 {
            // Opened from Finder/Spotlight: hand over to the crash-safe copy,
            // but only once it is really up.
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline {
                let started = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                    .contains { $0.processIdentifier != me }
                if started { exit(0) }
                usleep(100_000)
            }
            EventLog.write("launch agent did not start; running without crash protection")
        }
    }

    /// Start at login + restart after crashes.
    static func setEnabled(_ on: Bool) -> Bool {
        // Clean up registrations from older builds.
        try? SMAppService.agent(plistName: agentLabel + ".plist").unregister()
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }

        launchctl(["bootout", "\(domain)/\(agentLabel)"])
        if !on {
            try? FileManager.default.removeItem(at: plistURL)
            return false
        }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [Bundle.main.executablePath ?? "/Applications/Maben Awake.app/Contents/MacOS/Sleepwalker"],
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "com.maxbenschop.sleepwalker"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],   // restart after crash, not after Quit
            "ThrottleInterval": 5,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
        } catch {
            EventLog.write("could not write launch agent: \(error.localizedDescription)")
            return false
        }
        // Load it. RunAtLoad starts the launchd copy, which takes over from us.
        let rc = launchctl(["bootstrap", domain, plistURL.path])
        if rc != 0 { EventLog.write("launchctl bootstrap failed (\(rc))") }
        return isEnabled
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
