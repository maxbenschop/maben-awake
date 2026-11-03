import CoreGraphics
import Darwin
import Foundation
import IOKit
import SystemConfiguration

// Sleepwalker failsafe.
//
// A tiny root daemon (/Library/LaunchDaemons/com.maxbenschop.sleepwalker.failsafe.plist)
// that makes sure opening the lid always brings the Mac back, even when
// Sleepwalker itself is stuck. With the lid closed Sleepwalker turns the screen
// brightness to 0 and freezes apps; it undoes both when it sees the lid open.
// If Sleepwalker hangs, the screen stays black and apps stay frozen. Running as
// root, this daemon can't be frozen by anything in the user session.
//
// Sleepwalker writes its view of the lid to a heartbeat file whenever it
// changes. When the lid opens, this daemon waits for Sleepwalker to report
// "lid open, screen restored". If that doesn't happen:
//   after  6 s: unfreeze every stopped process of the console user and turn the
//               screen brightness back up;
//   after 16 s: if Sleepwalker still hasn't reported in, restart it.
//
// Usage:
//   sleepwalker-failsafe daemon                    run the watchdog (as root, from launchd)
//   sleepwalker-failsafe status                    print what the watchdog would see
//   sleepwalker-failsafe restore-brightness [0-1]  set brightness if it is ~0 (as the user)
//   sleepwalker-failsafe brightness                print the built-in display brightness
//   sleepwalker-failsafe --version

/// Bump when the daemon's behaviour changes; Sleepwalker offers to update an
/// installed failsafe whose version differs from the bundled one.
let version = "1"
let agentLabel = "com.maxbenschop.sleepwalker.agent"
let checkAfter: TimeInterval = 6
let restartAfter: TimeInterval = 16
let fallbackBrightness: Float = 0.5

/// Test hooks for tests/failsafe-test.sh (a root launchd daemon never has
/// these set): fake lid state from a file, a heartbeat path, faster timings,
/// and a dry run that logs recovery actions instead of performing them.
let env = ProcessInfo.processInfo.environment
let testLidFile = env["SLEEPWALKER_FAILSAFE_TEST_LID"]
let testHeartbeat = env["SLEEPWALKER_FAILSAFE_TEST_HEARTBEAT"]
let dryRun = env["SLEEPWALKER_FAILSAFE_DRY_RUN"] == "1"
let timeScale = env["SLEEPWALKER_FAILSAFE_TEST_FAST"] == "1" ? 0.25 : 1.0

// MARK: - Logging

let ownLog = "/Library/Logs/Sleepwalker-failsafe.log"

let stampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

/// Appends to our own log and, when it is a plain file owned by the console
/// user, to Sleepwalker's event log so `awake log` shows what happened.
func log(_ message: String, user: ConsoleUser? = nil) {
    let line = "\(stampFormatter.string(from: Date())) \(message)\n"
    if getuid() != 0 { FileHandle.standardError.write(Data(line.utf8)); return }
    appendSafely(line, to: ownLog, owner: 0, create: true)
    if let user { appendSafely("\(stampFormatter.string(from: Date())) failsafe: \(message)\n",
                               to: user.home + "/Library/Logs/Sleepwalker.log", owner: user.uid, create: false) }
}

/// Root writing into a user's directory: refuse symlinks, hard links and files
/// owned by anyone else, so the path can't be pointed at a system file.
func appendSafely(_ text: String, to path: String, owner: uid_t, create: Bool) {
    let fd = open(path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_NONBLOCK | (create ? O_CREAT : 0), 0o644)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == owner, st.st_nlink == 1 else { return }
    _ = text.withCString { write(fd, $0, strlen($0)) }
}

// MARK: - System state

struct ConsoleUser {
    let uid: uid_t
    let name: String
    let home: String
}

/// The user logged in at the Mac's screen, if any.
func consoleUser() -> ConsoleUser? {
    var uid: uid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
          name != "loginwindow", uid != 0, let pw = getpwuid(uid) else { return nil }
    return ConsoleUser(uid: uid, name: name, home: String(cString: pw.pointee.pw_dir))
}

func isLidClosed() -> Bool {
    if let testLidFile {
        return (try? String(contentsOfFile: testLidFile, encoding: .utf8))?.hasPrefix("closed") ?? false
    }
    let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard entry != 0 else { return false }
    defer { IOObjectRelease(entry) }
    return (IORegistryEntryCreateCFProperty(entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Bool) ?? false
}

/// What Sleepwalker last wrote (see Heartbeat.swift in the app).
struct Heartbeat: Decodable {
    var time: Double
    var pid: Int32?
    var lidClosed: Bool
    var dimmed: Bool
    var savedBrightness: Float?
    var quit: Bool?
}

func heartbeatPath(_ user: ConsoleUser) -> String {
    testHeartbeat ?? user.home + "/Library/Application Support/Sleepwalker/heartbeat.json"
}

/// Reads at most 64 KB from a regular file, without following symlinks or
/// blocking on a FIFO.
func readHeartbeat(_ user: ConsoleUser) -> Heartbeat? {
    let fd = open(heartbeatPath(user), O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
    var buffer = [UInt8](repeating: 0, count: 65536)
    let n = read(fd, &buffer, buffer.count)
    guard n > 0 else { return nil }
    return try? JSONDecoder().decode(Heartbeat.self, from: Data(buffer.prefix(n)))
}

enum Health {
    case fine(String)
    /// `stale`: Sleepwalker never reported the lid open (likely hung).
    case broken(String, stale: Bool, savedBrightness: Float?)
}

/// Has Sleepwalker undone its lid-closed state?
func health(_ user: ConsoleUser) -> Health {
    guard let hb = readHeartbeat(user) else { return .fine("no heartbeat, Sleepwalker not in use") }
    if hb.quit == true && !hb.dimmed { return .fine("Sleepwalker quit cleanly") }
    if hb.lidClosed {
        let age = Int(Date().timeIntervalSince1970 - hb.time)
        return .broken("Sleepwalker hasn't noticed the lid opening (last report \(age)s ago)",
                       stale: true, savedBrightness: hb.savedBrightness)
    }
    if hb.dimmed {
        return .broken("Sleepwalker saw the lid open but the screen is still dimmed",
                       stale: false, savedBrightness: hb.savedBrightness)
    }
    return .fine("Sleepwalker restored everything")
}

// MARK: - Recovery

/// SIGCONT every stopped process of `uid`. Returns how many were thawed.
func thawStopped(uid: uid_t) -> Int {
    if dryRun { log("dry run: would unfreeze stopped processes of uid \(uid)"); return 0 }
    var pids = [pid_t](repeating: 0, count: 16384)
    let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    guard count > 0 else { return 0 }
    var thawed = 0
    for pid in pids.prefix(count) where pid > 1 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == uid, info.pbi_status == UInt32(SSTOP) else { continue }
        if kill(pid, SIGCONT) == 0 { thawed += 1 }
    }
    return thawed
}

/// Runs a command, giving up after `timeout` so the daemon itself never hangs.
@discardableResult
func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(100_000) }
    if p.isRunning { p.terminate(); return -2 }
    return p.terminationStatus
}

/// Brightness lives in the user's session, so run ourselves there.
func restoreBrightness(_ user: ConsoleUser, to saved: Float?) -> Int32 {
    if dryRun { log("dry run: would restore brightness to \(saved.map { String($0) } ?? "default")"); return 0 }
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    var args = ["asuser", String(user.uid), me, "restore-brightness"]
    if let saved, saved > 0.05 { args.append(String(saved)) }
    return run("/bin/launchctl", args)
}

func restartSleepwalker(_ user: ConsoleUser) {
    if dryRun { log("dry run: would restart Sleepwalker"); return }
    let target = "gui/\(user.uid)/\(agentLabel)"
    run("/bin/launchctl", ["kill", "SIGKILL", target])
    sleep(1)
    let rc = run("/bin/launchctl", ["kickstart", target])
    log(rc == 0 ? "restarted Sleepwalker" : "could not restart Sleepwalker (launchctl \(rc)); is its launch agent loaded?",
        user: user)
}

// MARK: - Brightness (user mode)

/// Built-in display brightness via the private DisplayServices framework,
/// same as the app's Brightness.swift.
enum Brightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let fns: (get: GetFn, set: SetFn)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let g = dlsym(handle, "DisplayServicesGetBrightness"),
              let s = dlsym(handle, "DisplayServicesSetBrightness")
        else { return nil }
        return (unsafeBitCast(g, to: GetFn.self), unsafeBitCast(s, to: SetFn.self))
    }()

    private static var builtInDisplay: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    static func get() -> Float? {
        guard let fns else { return nil }
        var value: Float = 0
        return fns.get(builtInDisplay, &value) == 0 ? value : nil
    }

    static func set(_ value: Float) -> Bool {
        guard let fns else { return false }
        return fns.set(builtInDisplay, max(0, min(1, value))) == 0
    }
}

// MARK: - Daemon

func runDaemon() -> Never {
    setvbuf(stdout, nil, _IOLBF, 0)
    log("failsafe \(version) started")
    var wasClosed = isLidClosed()
    var openedAt: Date?
    var stage = 0

    while true {
        let closed = isLidClosed()
        if wasClosed && !closed { openedAt = Date(); stage = 0 }
        if closed { openedAt = nil }
        wasClosed = closed

        if let opened = openedAt, let user = consoleUser() {
            let elapsed = Date().timeIntervalSince(opened)
            if stage == 0 && elapsed >= checkAfter * timeScale {
                switch health(user) {
                case .fine:
                    openedAt = nil
                case .broken(let why, let stale, let saved):
                    let thawed = thawStopped(uid: user.uid)
                    let rc = restoreBrightness(user, to: saved)
                    log("lid opened \(Int(elapsed))s ago but \(why): unfroze \(thawed) processes, "
                        + "brightness restore \(rc == 0 ? "ok" : "failed (\(rc))")", user: user)
                    if stale { stage = 1 } else { openedAt = nil }
                }
            } else if stage == 1 && elapsed >= restartAfter * timeScale {
                if case .broken(let why, true, _) = health(user) {
                    log("still stuck after \(Int(elapsed))s (\(why)), restarting Sleepwalker", user: user)
                    _ = thawStopped(uid: user.uid)
                    restartSleepwalker(user)
                } else {
                    log("Sleepwalker recovered after being unfrozen", user: user)
                }
                openedAt = nil
            }
        } else if openedAt != nil && consoleUser() == nil {
            openedAt = nil   // nobody logged in at the screen
        }
        usleep(useconds_t(1_000_000 * timeScale))
    }
}

// MARK: - Commands

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "--version", "version":
    print(version)
case "daemon":
    runDaemon()
case "restore-brightness":
    let target = args.dropFirst().first.flatMap(Float.init) ?? fallbackBrightness
    guard let current = Brightness.get() else { log("brightness control unavailable"); exit(1) }
    if current > 0.01 { print("brightness already \(current)"); exit(0) }
    guard Brightness.set(target) else { log("could not set brightness"); exit(1) }
    print("brightness \(current) -> \(target)")
case "brightness":
    guard let current = Brightness.get() else { print("unavailable"); exit(1) }
    print(current)
case "status":
    print("failsafe \(version)")
    print("lid: \(isLidClosed() ? "closed" : "open")")
    guard let user = consoleUser() else { print("console user: none"); exit(0) }
    print("console user: \(user.name) (\(user.uid))")
    if let hb = readHeartbeat(user) {
        print("heartbeat: \(Int(Date().timeIntervalSince1970 - hb.time))s old, lidClosed=\(hb.lidClosed), "
            + "dimmed=\(hb.dimmed), quit=\(hb.quit ?? false), pid=\(hb.pid.map(String.init) ?? "?")")
    } else {
        print("heartbeat: none")
    }
    switch health(user) {
    case .fine(let why): print("if the lid opened now: fine (\(why))")
    case .broken(let why, let stale, _): print("if the lid opened now: would recover (\(why)\(stale ? ", may restart" : ""))")
    }
default:
    FileHandle.standardError.write(Data("usage: sleepwalker-failsafe daemon | status | restore-brightness [0-1] | brightness | --version\n".utf8))
    exit(64)
}
