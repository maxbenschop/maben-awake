import Foundation

/// A request from an external tool (Claude Code, a script…) to keep the Mac awake.
///
/// Leases are plain files in `~/Library/Application Support/Sleepwalker/leases/`.
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
    /// cron, or an app request.
    var isWork: Bool { app == nil && !name.hasSuffix("-wakeup") && !name.hasSuffix("-cron") }
}

enum LeaseStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Sleepwalker/leases", isDirectory: true)
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
