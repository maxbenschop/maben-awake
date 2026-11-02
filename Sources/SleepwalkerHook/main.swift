// sleepwalker-hook: the Claude Code hook, as a small compiled program.
//
// Claude Code runs it on every prompt and tool call with the hook JSON on
// stdin. It keeps a lease ("hold") alive while Claude works, releases it when
// Claude stops, and creates `need-<app>` leases for apps a tool call is about
// to use, so Sleepwalker can wake them. Same behaviour as `awake hook`, but
// without starting a shell and a dozen helper processes per call.
//
// Lease files: ~/Library/Application Support/Sleepwalker/leases/<name>
// containing "<expiry unix time> <owner pid> [app]".
import Foundation

let env = ProcessInfo.processInfo.environment
let home = FileManager.default.homeDirectoryForCurrentUser.path
let leaseDir = env["SLEEPWALKER_LEASES"] ?? home + "/Library/Application Support/Sleepwalker/leases"
let logPath = env["SLEEPWALKER_HOOK_LOG"] ?? home + "/Library/Logs/Sleepwalker-hooks.log"

// MARK: Leases

/// Same as the shell's `tr -c 'A-Za-z0-9._-' '_'`.
func safe(_ s: String) -> String {
    String(s.unicodeScalars.map { c in
        let ok = c.isASCII && (CharacterSet.alphanumerics.contains(c) || "._-".unicodeScalars.contains(c))
        return ok ? Character(c) : "_"
    })
}

func hold(_ name: String, minutes: Int, owner: pid_t, app: String? = nil) {
    let expiry = Int(Date().timeIntervalSince1970) + minutes * 60
    let line = "\(expiry) \(owner)" + (app.map { " " + $0 } ?? "") + "\n"
    try? line.write(toFile: leaseDir + "/" + safe(name), atomically: true, encoding: .utf8)
}

func release(_ name: String) { unlink(leaseDir + "/" + safe(name)) }

func need(_ app: String, owner: pid_t) {
    hold("need-\(safe(app))-\(owner)", minutes: 10, owner: owner, app: app)
}

/// Removes leases matching `prefix…suffix`.
func releaseMatching(prefix: String, suffix: String = "") {
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: leaseDir) else { return }
    for f in files where f.hasPrefix(prefix) && f.hasSuffix(suffix) { unlink(leaseDir + "/" + f) }
}

// MARK: Owner

/// The `claude` process this hook runs under (0 if none), so leases die with it.
func claudeAncestor() -> pid_t {
    var pid = getppid()
    while pid > 1 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
        let comm = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if comm.contains("claude") { return pid }
        pid = pid_t(info.pbi_ppid)
    }
    return 0
}

// MARK: App detection

let regexes: [NSRegularExpression] = [
    // Quotes may be escaped: osascript -e "tell application \"Dia\" to …"
    #"tell (?:application|app) \\?"([^"\\]+)\\?""#,          // osascript -e 'tell application "Dia" …'
    #"\bopen(?: -[a-zA-Z]+)* -a \\?"([^"\\]+)\\?""#,         // open -a "Visual Studio Code", open -g -a "X"
    #"\bopen(?: -[a-zA-Z]+)* -a ([A-Za-z0-9.]+)"#,          // open -a Dia, open -g -a TextEdit
].map { try! NSRegularExpression(pattern: $0) }

// agent-desktop (vercel-labs/agent-desktop) drives apps through the accessibility
// tree, which a frozen app can't answer. It names the app with `--app X` or as the
// argument of `launch` / `close-app`; ref actions (`click @s1:e8`) name none, but
// they follow a snapshot whose lease still covers the app.
let agentDesktopRegexes: [NSRegularExpression] = [
    #"--app(?:=| +)(?:\\?"([^"\\]+)\\?"|'([^']+)'|([A-Za-z0-9.][A-Za-z0-9._-]*))"#,
    #"agent-desktop +(?:launch|close-app)(?: +--?[a-zA-Z-]+)* +(?:\\?"([^"\\]+)\\?"|'([^']+)'|([A-Za-z0-9.][A-Za-z0-9._-]*))"#,
].map { try! NSRegularExpression(pattern: $0) }

func appsMentioned(in command: String) -> Set<String> {
    var apps = Set<String>()
    let range = NSRange(command.startIndex..., in: command)
    for re in regexes {
        for m in re.matches(in: command, range: range) {
            if let r = Range(m.range(at: 1), in: command) { apps.insert(String(command[r])) }
        }
    }
    if command.contains("agent-desktop") {
        for re in agentDesktopRegexes {
            for m in re.matches(in: command, range: range) {
                for i in 1..<m.numberOfRanges {
                    if let r = Range(m.range(at: i), in: command) { apps.insert(String(command[r])) }
                }
            }
        }
    }
    if command.range(of: #"\b(docker|kubectl)\b"#, options: .regularExpression) != nil { apps.insert("docker") }
    return apps.subtracting(["", "System Events", "Finder"])
}

// MARK: Main

let data = FileHandle.standardInput.readDataToEndOfFile()
let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
let input = json["tool_input"] as? [String: Any] ?? [:]
let sid = json["session_id"] as? String ?? "unknown"
let event = json["hook_event_name"] as? String ?? ""
let tool = json["tool_name"] as? String ?? ""
let name = "claude-" + String(sid.prefix(8))
let owner = claudeAncestor()

try? FileManager.default.createDirectory(atPath: leaseDir, withIntermediateDirectories: true)

// Log, trimmed to the last 500 lines once it passes 2000.
if let fh = FileHandle(forWritingAtPath: logPath) ?? {
    FileManager.default.createFile(atPath: logPath, contents: nil); return FileHandle(forWritingAtPath: logPath)
}() {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let end = fh.seekToEndOfFile()
    fh.write(Data("\(f.string(from: Date())) \(name) \(event) \(tool)\n".utf8))
    try? fh.close()
    if end > 120_000, let text = try? String(contentsOfFile: logPath, encoding: .utf8) {
        let lines = text.split(separator: "\n")
        if lines.count > 2000 { try? (lines.suffix(500).joined(separator: "\n") + "\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
    }
}

if event == "PreToolUse" {
    // Work that outlives the turn gets its own lease, which Stop does not release.
    switch tool {
    case "ScheduleWakeup":
        if input["stop"] as? Bool == true {
            release(name + "-wakeup")
        } else {
            let delay = (input["delaySeconds"] as? NSNumber)?.intValue ?? 1800
            hold(name + "-wakeup", minutes: (delay + 59) / 60 + 5, owner: owner)
        }
    case "CronCreate": hold(name + "-cron", minutes: 1440, owner: owner)
    case "CronDelete": release(name + "-cron")
    case "Monitor": hold(name + "-monitor", minutes: 60, owner: owner)
    case "Bash":
        if input["run_in_background"] as? Bool == true { hold(name + "-bg", minutes: 30, owner: owner) }
    default: break
    }

    // Wake the apps this tool call is about to use.
    let lower = tool.lowercased()
    if lower.contains("chrome") || lower.contains("browser") || lower.contains("playwright") || lower.contains("preview_") {
        need("browser", owner: owner)
    }
    if tool == "Bash", let command = input["command"] as? String {
        for app in appsMentioned(in: command) { need(app, owner: owner) }
    }
}

switch event {
case "Stop":
    release(name)
    releaseMatching(prefix: "need-", suffix: "-\(owner)")
case "SessionEnd":
    release(name)
    releaseMatching(prefix: name + "-")
    releaseMatching(prefix: "need-", suffix: "-\(owner)")
case "PreToolUse":
    // A tool can run long (builds), so hold 2 h while one runs; between tools
    // 15 min is plenty and limits a stale lease if Stop is ever missed.
    hold(name, minutes: 120, owner: owner)
default:
    hold(name, minutes: 15, owner: owner)
}
exit(0)
