import Foundation

/// The app was called Sleepwalker until 1.5. Everything that still knows that
/// name lives here: what an install of 1.4 or earlier left on the Mac, and how
/// it is moved to the current names. (The root failsafe and the sudoers rule
/// are renamed by `install-failsafe.sh`, which runs with a password.)
enum Legacy {
    /// The bundle ID keeps the old name for now: 1.4 only installs an update
    /// signed with its own ID, so it has to change in a later release. The
    /// updater already accepts the new one (`Updater.acceptedIdentifiers`).
    static let bundleID = "com.maxbenschop.sleepwalker"
    static let nextBundleID = "gg.maben.awake"

    static let agentLabel = "com.maxbenschop.sleepwalker.agent"
    /// The hook under its old name. The app bundle keeps a link with this name
    /// so agent sessions that started before the update still reach it.
    static let hookName = "sleepwalker-hook"

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    static let supportFolder = home.appendingPathComponent("Library/Application Support/Sleepwalker")
    private static let logs = ["Sleepwalker.log", "Sleepwalker-hooks.log"]

    /// Moves requests and logs to their current names. Safe to run at every start.
    static func moveFiles() {
        let fm = FileManager.default
        let leases = supportFolder.appendingPathComponent("leases")
        for file in (try? fm.contentsOfDirectory(at: leases, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.moveItem(at: file, to: LeaseStore.directory.appendingPathComponent(file.lastPathComponent))
        }
        // Without its heartbeat file, a failsafe installed by 1.4 does nothing until it is replaced.
        try? fm.removeItem(at: supportFolder)
        for name in logs {
            let old = home.appendingPathComponent("Library/Logs/" + name)
            let new = home.appendingPathComponent("Library/Logs/" + name.replacingOccurrences(of: "Sleepwalker", with: "MabenAwake"))
            if fm.fileExists(atPath: new.path) { try? fm.removeItem(at: old) } else { try? fm.moveItem(at: old, to: new) }
        }
    }

    /// Settings saved under another bundle ID (once the ID changes), copied over once.
    static func moveSettings() {
        let defaults = UserDefaults.standard
        guard let id = Bundle.main.bundleIdentifier, id != bundleID, !defaults.bool(forKey: "movedSettings"),
              let old = UserDefaults.standard.persistentDomain(forName: bundleID) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: "movedSettings")
    }
}
