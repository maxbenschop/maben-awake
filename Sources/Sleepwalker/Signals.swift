import Darwin

/// The only place Sleepwalker sends signals to other processes.
///
/// `kill()` treats some pids specially: `-1` signals every process we're
/// allowed to signal, `0` our own process group, and other negative values a
/// whole process group. `NSRunningApplication.processIdentifier` is `-1` for an
/// app without a process (e.g. one that is just quitting), so freezing such an
/// app with a plain `kill(pid, SIGSTOP)` froze the whole user session: Dock,
/// menu bar, Control Center and Sleepwalker's own dependencies. Every signal
/// therefore goes through `send`, which only ever targets one real process.
enum Signals {
    /// True for a pid that names exactly one process other than launchd and us.
    static func isSafeTarget(_ pid: pid_t) -> Bool {
        pid > 1 && pid != getpid()
    }

    /// Sends `signal` to `pid` only. Returns false (and sends nothing) for an
    /// unsafe target or when `kill` fails.
    @discardableResult
    static func send(_ signal: Int32, to pid: pid_t) -> Bool {
        guard isSafeTarget(pid) else { return false }
        return kill(pid, signal) == 0
    }
}
