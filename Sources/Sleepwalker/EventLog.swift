import Foundation

/// Append-only log of every keep-awake decision (why the Mac is kept awake,
/// lid and power changes, sleep and wake, crash recovery, overheating…) in
/// ~/Library/Logs/Sleepwalker.log, trimmed to the last
/// 15000 lines (weeks of use) once it passes 3 MB.
/// Read it with `awake log`.
enum EventLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Sleepwalker.log")

    /// Local time, so the log lines up with when things happened at the Mac.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        let stamp = formatter.string(from: Date())
        let line = "\(stamp) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        trimIfNeeded()
    }

    private static func trimIfNeeded() {
        // Cheap size check first; only read the file once it's grown past 3 MB.
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 3_000_000, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        try? lines.suffix(15000).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
