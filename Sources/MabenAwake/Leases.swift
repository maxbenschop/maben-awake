import AppKit

/// A request from an external tool (Claude Code, a script…) to keep the Mac awake.
///
/// Leases are plain files in `~/Library/Application Support/MabenAwake/leases/`.
/// File name = lease name, content = "<expiry unix timestamp> [owner pid] [app]". The
/// `awake` CLI writes them; the app just reads the directory. Leases that expired
/// or whose owner process is gone are deleted.
struct Lease: Identifiable, Hashable {
    let name: String
    let expires: Date
    /// App this lease asks to unfreeze (`awake need`), by name, bundle ID or "browser".
    let app: String?
    /// Process that holds the lease (0 = none), e.g. the `claude` or `codex` CLI.
    let owner: pid_t
    var id: String { name }
    var remaining: TimeInterval { expires.timeIntervalSinceNow }

    /// An AI turn or `awake run` in progress, as opposed to a scheduled wake-up,
    /// cron, an app request, or work an agent left running in the background
    /// (`-bg`, `-detached`): those keep the Mac awake for hours, but nobody is
    /// working, so apps stay frozen and the menu doesn't say an AI is working.
    var isWork: Bool { app == nil && !["-wakeup", "-cron", "-bg", "-detached"].contains { name.hasSuffix($0) } }
}

enum LeaseStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MabenAwake/leases", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Active leases, sorted by name. Deletes expired ones as a side effect.
    static func active() -> [Lease] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var leases: [Lease] = []
        for file in files where !file.lastPathComponent.hasPrefix(".") {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let parts = text.split(whereSeparator: \.isWhitespace)
            guard let first = parts.first, let ts = TimeInterval(first) else { continue }
            let expires = Date(timeIntervalSince1970: ts)
            let owner = parts.count > 1 ? pid_t(parts[1]) ?? 0 : 0
            let ownerAlive = owner <= 0 || kill(owner, 0) == 0
            let app = parts.count > 2 ? parts[2...].joined(separator: " ") : nil
            if expires > Date() && ownerAlive {
                leases.append(Lease(name: file.lastPathComponent, expires: expires, app: app, owner: owner))
            } else {
                try? fm.removeItem(at: file)
            }
        }
        return leases.sorted { $0.name < $1.name }
    }

    static func remove(_ lease: Lease) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(lease.name))
    }

    static func removeAll() {
        for lease in active() { remove(lease) }
    }
}

/// The apps frozen right now, for the agent hook: a tool call that names one
/// wakes it, and a failed one is told which apps are frozen. One
/// `<bundle ID>\t<name>` per line in `~/Library/Application Support/MabenAwake/frozen`
/// (outside the leases folder, which the app watches), after a line with the
/// app's pid: the hook ignores a list whose app is gone (force quit, crash).
@MainActor
enum FrozenList {
    static let file = LeaseStore.directory.deletingLastPathComponent().appendingPathComponent("frozen")
    private static var written: String?

    static func write(_ apps: [NSRunningApplication]) {
        let text = "pid \(ProcessInfo.processInfo.processIdentifier)\n" + apps.compactMap { app -> String? in
            guard let id = app.bundleIdentifier else { return nil }
            let name = (app.localizedName ?? id).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
            return id + "\t" + name + "\n"
        }.sorted().joined()
        guard text != written else { return }
        try? text.write(to: file, atomically: true, encoding: .utf8)
        written = text
    }
}
