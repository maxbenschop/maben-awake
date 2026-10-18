import Foundation

/// Small append-only log of notable events (crash recovery, overheating, …)
/// in ~/Library/Logs/Sleepwalker.log, trimmed to the last 1000 lines.
enum EventLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Sleepwalker.log")

    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
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
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1200 else { return }
        try? lines.suffix(1000).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
