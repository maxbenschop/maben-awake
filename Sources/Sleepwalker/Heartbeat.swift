import Foundation

/// Sleepwalker's view of the lid, for the root failsafe daemon
/// (Sources/SleepwalkerFailsafe). Written only when it changes, plus at start
/// and quit. When the lid opens and this file still says "lid closed" or
/// "dimmed", the daemon knows Sleepwalker is stuck and brings the screen and
/// frozen apps back itself.
enum Heartbeat {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Sleepwalker/heartbeat.json")

    private struct State: Encodable, Equatable {
        var time: Double
        var pid: Int32
        var lidClosed: Bool
        var dimmed: Bool
        var savedBrightness: Float?
        var quit: Bool
    }

    private static var last: State?

    static func write(lidClosed: Bool, savedBrightness: Float?, quit: Bool = false) {
        var state = State(time: 0, pid: getpid(), lidClosed: lidClosed, dimmed: savedBrightness != nil,
                          savedBrightness: savedBrightness, quit: quit)
        guard state != last else { return }
        last = state
        state.time = Date().timeIntervalSince1970
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
