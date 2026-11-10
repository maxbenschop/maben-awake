// maben-awake-hook: the hook every AI agent calls, as a small compiled program.
//
// Claude Code, Codex, Cursor, Gemini CLI, GitHub Copilot, OpenCode, Qwen Code,
// Droid, Devin, Augment and Kiro run it on every prompt and tool call with the
// hook JSON on stdin. Each agent names its events and fields a little
// differently; this program reads them all (see "Input" below). Agents other
// than Claude Code call it with `--agent <id>`, and with `--event <name>` where
// the JSON may not say which event it is. It keeps a lease ("hold") alive
// while the agent works, releases it when the agent stops, and creates
// `need-<app>` leases for apps a tool call is about to use, so Maben Awake can
// wake them. Same behaviour as `awake hook`, but without starting a shell and
// a dozen helper processes per call.
//
// Lease files: ~/Library/Application Support/MabenAwake/leases/<name>
// containing "<expiry unix time> <owner pid> [app]".
import Foundation

let env = ProcessInfo.processInfo.environment
let home = FileManager.default.homeDirectoryForCurrentUser.path
let leaseDir = env["MABEN_AWAKE_LEASES"] ?? home + "/Library/Application Support/MabenAwake/leases"
let logPath = env["MABEN_AWAKE_HOOK_LOG"] ?? home + "/Library/Logs/MabenAwake-hooks.log"

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

// MARK: Input

func argument(_ flag: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let data = FileHandle.standardInput.readDataToEndOfFile()
let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

/// Which agent called the hook: `--agent <id>`, Claude Code otherwise. Cursor
/// and Devin also run the hooks in Claude Code's settings, without the flag.
let agent: String = {
    if let name = argument("--agent") { return safe(name.lowercased()) }
    if json["cursor_version"] != nil { return "cursor" }
    if env["DEVIN_PROJECT_DIR"] != nil { return "devin" }
    return "claude"
}()

/// What happened, whatever the agent calls it.
enum Kind { case prompt, toolStart, toolEnd, stop, sessionEnd, other }

let event = argument("--event") ?? json["hook_event_name"] as? String ?? json["event"] as? String ?? ""
let kind: Kind = {
    switch event.lowercased() {
    case "userpromptsubmit", "userpromptsubmitted", "promptsubmit", "beforesubmitprompt", "beforeagent": return .prompt
    case "pretooluse", "beforetool", "beforeshellexecution", "beforemcpexecution": return .toolStart
    case "posttooluse", "posttoolusefailure", "aftertool", "aftershellexecution", "aftermcpexecution": return .toolEnd
    // Interrupt: Codex's turn was stopped by the user. AfterAgent: Gemini CLI's end of turn.
    case "stop", "stopfailure", "interrupt", "afteragent", "agentstop": return .stop
    case "sessionend": return .sessionEnd
    // Droid reports a cancelled turn as a notification that it is waiting for input.
    case "notification": return json["notification_type"] as? String == "idle_prompt" ? .stop : .other
    default: return .other
    }
}()

let sid = json["session_id"] as? String ?? json["sessionId"] as? String ?? json["conversation_id"] as? String ?? "unknown"
let tool = json["tool_name"] as? String ?? json["toolName"] as? String ?? ""
/// The tool's arguments. Copilot may send them as a JSON string.
let input: [String: Any] = {
    for key in ["tool_input", "toolArgs"] {
        if let object = json[key] as? [String: Any] { return object }
        if let text = json[key] as? String, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { return object }
    }
    return [:]
}()
/// Every agent's name for its tool that runs a shell command.
let shellTools: Set<String> = ["bash", "shell", "exec", "exec_command", "local_shell", "run_shell_command", "execute",
                               "execute_bash", "launch-process", "run_in_terminal"]
let isShell = shellTools.contains(tool.lowercased()) || event.lowercased() == "beforeshellexecution"
/// Claude Code sends the command as a string, Codex may send an argument list,
/// and Cursor's shell event has it at the top level.
let command = (input["command"] as? String) ?? (input["command"] as? [String])?.joined(separator: " ") ?? (json["command"] as? String)

// MARK: Owner

/// Part of the process name of each agent, to find the process the hook runs under.
let processNames: [String: [String]] = [
    "devin": ["devin", "windsurf"], "auggie": ["auggie", "augment"], "droid": ["droid", "factory"],
]
/// Agents installed with npm run as `node <path>/<agent>`.
let interpreters: Set<String> = ["node", "bun", "deno"]

/// The first arguments of a process (its own name and, for a script, the script's path).
func arguments(of pid: pid_t) -> [String] {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
    let count = min(Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) }), 2)
    var i = 4
    while i < size, buffer[i] != 0 { i += 1 }    // the executable's path
    while i < size, buffer[i] == 0 { i += 1 }
    var args: [String] = []
    while i < size, args.count < count {
        var j = i
        while j < size, buffer[j] != 0 { j += 1 }
        args.append(String(decoding: buffer[i..<j], as: UTF8.self))
        i = j + 1
    }
    return args
}

/// The agent process this hook runs under (0 if none), so leases die with it.
func agentAncestor() -> pid_t {
    let names = processNames[agent] ?? [agent]
    var pid = getppid()
    while pid > 1 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
        let comm = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }.lowercased()
        if names.contains(where: { comm.contains($0) }) { return pid }
        if interpreters.contains(comm), arguments(of: pid).contains(where: { arg in names.contains { arg.lowercased().contains($0) } }) { return pid }
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

// Claude Code's session IDs are random, so the start identifies one. Other agents
// number sessions by time and two started close together begin the same; their end differs.
let name = agent + "-" + String(agent == "claude" ? sid.prefix(8) : sid.suffix(8))
let owner = agentAncestor()

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

if kind == .toolStart {
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
    default:
        // A shell command left running in the background (each agent has its own flag for it).
        if isShell, ["run_in_background", "is_background", "background"].contains(where: { input[$0] as? Bool == true }) {
            hold(name + "-bg", minutes: 30, owner: owner)
        }
    }

    // Wake the apps this tool call is about to use.
    let lower = tool.lowercased()
    if lower.contains("chrome") || lower.contains("browser") || lower.contains("playwright") || lower.contains("preview_") {
        need("browser", owner: owner)
    }
    if isShell, let command {
        for app in appsMentioned(in: command) { need(app, owner: owner) }
    }
}

// Cursor only reports a tool once it has finished (see Integration.swift), so the
// apps a command names are woken then: in time for the agent's next try.
if agent == "cursor", kind == .toolEnd, isShell, let command {
    for app in appsMentioned(in: command) { need(app, owner: owner) }
}

switch kind {
case .stop:
    release(name)
    releaseMatching(prefix: "need-", suffix: "-\(owner)")
case .sessionEnd:
    release(name)
    releaseMatching(prefix: name + "-")
    releaseMatching(prefix: "need-", suffix: "-\(owner)")
case .toolStart:
    // A tool can run long (builds), so hold 2 h while one runs; between tools
    // 15 min is plenty and limits a stale lease if Stop is ever missed.
    hold(name, minutes: 120, owner: owner)
default:
    // Cursor doesn't say when a tool starts, so its hold has to cover a long tool from the start.
    hold(name, minutes: agent == "cursor" ? 120 : 15, owner: owner)
}
exit(0)   // prints nothing: no agent takes that for a decision
