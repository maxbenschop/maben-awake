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
// The agent should never have to think about any of this, so the hook does
// the work an agent used to be told to do:
// - work left running in the background keeps the Mac awake until it ends
//   (Claude Code lists it at the end of every turn);
// - a tool call that names a frozen app wakes it (the app writes the list of
//   frozen apps, see `frozenPath`);
// - if a command still fails while apps are frozen, Claude Code gets one line
//   saying so (and the app is woken when the error names it).
//
// Lease files: ~/Library/Application Support/MabenAwake/leases/<name>
// containing "<expiry unix time> <owner pid> [app]".
import Foundation
import CoreServices

let env = ProcessInfo.processInfo.environment
let home = FileManager.default.homeDirectoryForCurrentUser.path
let leaseDir = env["MABEN_AWAKE_LEASES"] ?? home + "/Library/Application Support/MabenAwake/leases"
let logPath = env["MABEN_AWAKE_HOOK_LOG"] ?? home + "/Library/Logs/MabenAwake-hooks.log"
/// Apps Maben Awake has frozen right now, one `<bundle ID>\t<name>` per line.
/// Tests that move the leases elsewhere get no list unless they name one.
let frozenPath: String? = env["MABEN_AWAKE_FROZEN"]
    ?? (env["MABEN_AWAKE_LEASES"] == nil ? home + "/Library/Application Support/MabenAwake/frozen" : nil)

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

func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: options)
}

/// Every capture group of every match, for each pattern.
func captures(_ patterns: [NSRegularExpression], in text: String) -> Set<String> {
    var found = Set<String>()
    let range = NSRange(text.startIndex..., in: text)
    for re in patterns {
        for m in re.matches(in: text, range: range) {
            for i in 1..<m.numberOfRanges {
                if let r = Range(m.range(at: i), in: text) { found.insert(String(text[r])) }
            }
        }
    }
    return found
}

func contains(_ re: NSRegularExpression, _ text: String) -> Bool {
    re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

/// A value in quotes: "X", \"X\" (inside a double-quoted string) or 'X'.
let quoted = #"(?:\\?"([^"\\]+)\\?"|'([^']+)')"#

/// How 1.5 recognised the apps a command uses. These wake the app whether or
/// not it is frozen (an app the AI launches this way is quit again by the
/// app's clean-up when the AI is done, with the lid closed).
let regexes: [NSRegularExpression] = [
    // Quotes may be escaped: osascript -e "tell application \"Dia\" to …"
    #"tell (?:application|app) \\?"([^"\\]+)\\?""#,          // osascript -e 'tell application "Dia" …'
    #"\bopen(?: -[a-zA-Z]+)* -a \\?"([^"\\]+)\\?""#,         // open -a "Visual Studio Code", open -g -a "X"
    #"\bopen(?: -[a-zA-Z]+)* -a ([A-Za-z0-9.]+)"#,          // open -a Dia, open -g -a TextEdit
].map { regex($0) }

/// Added in 1.6. These only wake an app that is frozen right now: `open X.app`
/// and `pkill` are mostly an AI relaunching a build it is working on, which
/// must not become a request the clean-up would later quit.
let moreRegexes: [NSRegularExpression] = [
    #"\bopen(?: -[a-zA-Z]+)* -b ([A-Za-z0-9.-]+)"#,         // open -b com.apple.TextEdit
    #"tell (?:application|app) id \\?"([^"\\]+)\\?""#,       // tell application id "com.apple.Notes"
].map { regex($0) }

/// `open "/Applications/Visual Studio Code.app"`, `open -n build/Chain.app`: the path.
let openAppRegex = regex(#"\bopen(?: -[a-zA-Z-]+(?: [A-Z_]+=\S+)?)* (?:\\?"([^"\\]*\.app)/?\\?"|'([^']*\.app)/?'|([^\s"';&|]*\.app)\b)"#)

/// The app a path to an `.app` names, unless the path is a build outside the
/// Applications folders: relaunching a build doesn't need the installed copy
/// of the same app awake. A bare `Chain.app` could be either and counts.
func installedApp(atPath path: String) -> String? {
    guard let r = path.range(of: #"([^/]+)\.app$"#, options: .regularExpression) ?? path.range(of: #"([^/]+)\.app(?=/)"#, options: .regularExpression)
    else { return nil }
    let before = path[..<r.lowerBound]
    let installed = before.isEmpty || ["/Applications/", "~/Applications/", "$HOME/Applications/", "/System/Applications/"].contains { before.hasSuffix($0) && !before.dropLast($0.count).contains("/") }
        || before.hasPrefix(home + "/Applications/")
    return installed ? String(path[r].dropLast(4)) : nil
}

/// An app that quits cleanly on SIGTERM (Chromium and Electron apps among them)
/// can't while it is frozen, so a kill wakes it: pkill -x Chain, killall "Visual Studio Code",
/// pkill -f "Chain.app/Contents/MacOS/Chain". Only what looks like an app's name counts
/// (`pkill -f "next start"` names no app).
let killRegex = regex(#"\b(?:pkill|killall)(?: +-[a-zA-Z0-9]+)* +(?:\#(quoted)|([^\s"';&|]+))"#)
func appsKilled(in command: String) -> Set<String> {
    Set(captures([killRegex], in: command).compactMap { target in
        if target.contains(".app") { return installedApp(atPath: String(target[..<(target.range(of: ".app")!.upperBound)])) }
        let isName = target.first?.isUppercase == true && target.range(of: #"^[A-Za-z0-9][A-Za-z0-9 ._()-]*$"#, options: .regularExpression) != nil
        return isName ? target : nil
    })
}

/// AppleScript and JavaScript for Automation name apps in more ways than `tell`.
let scriptRegexes: [NSRegularExpression] = [
    #"\b(?:application|app) \\?"([^"\\]+)\\?""#,            // quit app "X", activate application "X", id of app "X"
    #"\bprocess \\?"([^"\\]+)\\?""#,                        // System Events: tell process "Xcode"
    #"\bApplication\(\s*\#(quoted)\s*\)"#,                  // JXA: Application("Dia"), Application('Notes')
].map { regex($0) }
let scripting = regex(#"osascript|AppleScript|NSAppleScript|\.scpt\b|JavaScript"#, .caseInsensitive)

/// `open https://…` or `open page.html`: the default browser.
let opensBrowser = regex(#"\bopen(?: -[a-zA-Z]+)* +\\?["']?(?:https?://|file://|[^\s"';&|]+\.html?\b)"#)

// agent-desktop (vercel-labs/agent-desktop) drives apps through the accessibility
// tree, which a frozen app can't answer. It names the app with `--app X` or as the
// argument of `launch` / `close-app`; ref actions (`click @s1:e8`) name none, but
// they follow a snapshot whose lease still covers the app.
let agentDesktopRegexes: [NSRegularExpression] = [
    #"--app(?:=| +)(?:\\?"([^"\\]+)\\?"|'([^']+)'|([A-Za-z0-9.][A-Za-z0-9._-]*))"#,
    #"agent-desktop +(?:launch|close-app)(?: +--?[a-zA-Z-]+)* +(?:\\?"([^"\\]+)\\?"|'([^']+)'|([A-Za-z0-9.][A-Za-z0-9._-]*))"#,
].map { regex($0) }

let notApps: Set<String> = ["", "System Events", "Finder"]

/// The apps a command uses, as 1.5 found them.
func appsMentioned(in command: String) -> Set<String> {
    var apps = captures(regexes, in: command)
    if command.contains("agent-desktop") { apps.formUnion(captures(agentDesktopRegexes, in: command)) }
    if command.range(of: #"\b(docker|kubectl)\b"#, options: .regularExpression) != nil { apps.insert("docker") }
    return apps.subtracting(notApps)
}

/// The apps a command uses that only the 1.6 patterns find (still to be
/// checked against the frozen apps).
func moreAppsMentioned(in command: String) -> Set<String> {
    var apps = captures(moreRegexes, in: command).union(appsKilled(in: command))
        .union(captures([openAppRegex], in: command).compactMap(installedApp(atPath:)))
    if contains(scripting, command) { apps.formUnion(captures(scriptRegexes, in: command)) }
    if contains(opensBrowser, command) { apps.insert("browser") }
    return apps.subtracting(notApps)
}

// MARK: Frozen apps

struct FrozenApp { let bundle: String; let name: String }

/// The apps Maben Awake has frozen right now (empty with the lid open, so
/// everything below costs nothing then).
let frozen: [FrozenApp] = {
    guard let path = frozenPath, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    let lines = text.split(separator: "\n")
    // The app writes its pid first; a list left behind by an app that was force quit means nothing.
    if let first = lines.first, first.hasPrefix("pid ") {
        guard let pid = pid_t(first.dropFirst(4)), pid > 1, kill(pid, 0) == 0 || errno == EPERM else { return [] }
    }
    return lines.compactMap { line in
        let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return FrozenApp(bundle: parts[0], name: parts[1])
    }
}()

/// The frozen app a lease's app string means, matched the way the app does
/// (`Model.matches`): bundle ID, name, start of the name, or end of the bundle ID.
func frozenApp(_ want: String) -> FrozenApp? {
    let w = want.lowercased()
    if w == "browser" { return defaultBrowser.flatMap { id in frozen.first { $0.bundle.lowercased() == id } } }
    return frozen.first { app in
        let id = app.bundle.lowercased(), n = app.name.lowercased()
        return w == id || w == n || n.hasPrefix(w) || id.hasSuffix("." + w)
    }
}

/// Bundle ID of the default web browser (only looked up when a command opens a link).
var defaultBrowser: String? {
    if let id = env["MABEN_AWAKE_BROWSER"] { return id.lowercased() }
    guard let url = LSCopyDefaultApplicationURLForURL(URL(string: "https://example.com")! as CFURL, .all, nil)?.takeRetainedValue() as URL?
    else { return nil }
    return Bundle(url: url)?.bundleIdentifier?.lowercased()
}

/// Frozen apps that `text` names. Strict (a command about to run): the name or
/// bundle ID where a command addresses an app (`-a`, `-b`, `--app`, `process`,
/// `id`, `pkill`, `killall`), the name as `<name>.app` after `open`
/// or a kill, or in quotes in an `osascript` call. A name in a path or in a
/// `defaults` domain, or asked about with `pgrep` or `lsappinfo`, doesn't count:
/// nothing there needs the app to answer.
/// Loose (an error message): the name or bundle ID anywhere, as a word.
func frozenApps(namedIn text: String, loose: Bool) -> [FrozenApp] {
    guard !frozen.isEmpty, !text.isEmpty else { return [] }
    let lower = text.lowercased()
    let script = text.contains("osascript")
    return frozen.filter { app in
        let id = NSRegularExpression.escapedPattern(for: app.bundle)
        if app.bundle.contains("."), lower.contains(app.bundle.lowercased()) {
            let pattern = loose ? #"(?<![\w.-])\#(id)(?![\w-])"#
                : #"(?:-b|--app|--app=|\bid) +\\?["']?\#(id)(?![\w-])"#
            if contains(regex(pattern, .caseInsensitive), text) { return true }
        }
        guard app.name.count >= 2, !notApps.contains(app.name),
              loose ? lower.contains(app.name.lowercased()) : text.contains(app.name) else { return false }
        let name = NSRegularExpression.escapedPattern(for: app.name)
        if loose { return contains(regex(#"(?<![\w-])\#(name)(?![\w-])"#, .caseInsensitive), text) }
        let addressed = #"(?:-a|--app|--app=|\bprocess|\bpkill(?: +-\w+)*|\bkillall(?: +-\w+)*) +\\?["']?\#(name)(?![\w-])"#
        let bundle = #"\b(?:open|pkill|killall)\b[^\n;&|]*?(?:(?<![\w/-])|(?<![^\s"'])(?:~|\$HOME|/System)?/Applications/)\#(name)\.app\b"#
        let quoted = #"(?:\\?"\#(name)\\?"|'\#(name)')"#
        return contains(regex(addressed), text) || contains(regex(bundle), text) || (script && contains(regex(quoted), text))
    }
}

/// String values in a tool's arguments, for tools other than the shell.
func strings(in value: Any, depth: Int = 0) -> [(key: String?, value: String)] {
    guard depth < 4 else { return [] }
    if let object = value as? [String: Any] {
        return object.flatMap { key, v -> [(key: String?, value: String)] in
            if let s = v as? String { return [(key, s)] }
            if let list = v as? [String] { return list.map { (key, $0) } }
            return strings(in: v, depth: depth + 1)
        }
    }
    if let list = value as? [Any] { return list.flatMap { strings(in: $0, depth: depth + 1) } }
    return []
}

/// Frozen apps that an MCP or computer-use tool call names in its arguments: in
/// a field called `app`, `apps`, `bundle_id`…, or as a value that is a frozen
/// app's bundle ID. (Not a value that is just a name: a browser tool's `"action": "screenshot"`
/// isn't Apple's Screenshot app.)
func appsInArguments() -> Set<String> {
    let appKeys: Set<String> = ["app", "apps", "app_name", "appname", "application", "applications", "bundle_id", "bundleid"]
    var apps = Set<String>()
    for (key, value) in strings(in: input) {
        if let key, appKeys.contains(key.lowercased()), let app = frozenApp(value) { apps.insert(app.bundle) }
        for app in frozen where value.caseInsensitiveCompare(app.bundle) == .orderedSame { apps.insert(app.bundle) }
    }
    return apps
}

// MARK: Background work

/// Statuses of a background task that has ended.
let finished: Set<String> = ["completed", "failed", "killed", "stopped", "cancelled", "canceled", "error", "done", "exited"]

/// The command without heredoc bodies and quoted text, where `&` and words
/// like `nohup` are data (URLs, AppleScript, code being written to a file).
func shellWords(_ command: String) -> String {
    var text = withoutHeredocs(command)
    for pattern in [#"'[^']*'"#, #""(?:[^"\\]|\\.)*""#] {
        text = regex(pattern).stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " '' ")
    }
    return text
}

let heredoc = regex(#"<<-?\s*['"]?(\w+)['"]?[^\n]*\n[\s\S]*?\n\s*\1(?=\s|$)"#)
func withoutHeredocs(_ command: String) -> String {
    guard command.contains("<<") else { return command }
    return heredoc.stringByReplacingMatches(in: command, range: NSRange(command.startIndex..., in: command), withTemplate: " ")
}

/// A command that leaves something running after it returns: `nohup`, or a
/// lone `&` that nothing in the command waits for or kills again.
func detaches(_ command: String) -> Bool {
    let words = shellWords(command)
    if words.range(of: #"\b(nohup|setsid|disown)\b"#, options: .regularExpression) != nil { return true }
    guard words.range(of: #"(?<![&>|<\\])&(?=\s|$|\))"#, options: .regularExpression) != nil else { return false }
    return words.range(of: #"\b(wait|kill|pkill)\b"#, options: .regularExpression) == nil
}

// MARK: Hint after a failure

/// Errors that a frozen app causes: Apple events and accessibility calls that
/// get no answer, and commands that hang until they time out.
let symptom = regex(#"-1712|-1708|-609|AppleEvent timed out|timed out|time out|timeout|not responding|isn.t responding|Connection is invalid|cannot ?complete|-25204|kAXError"#, .caseInsensitive)
/// The same, but only codes an app's own output wouldn't print by accident.
let strongSymptom = regex(#"-1712|-609|AppleEvent timed out|Connection is invalid|-25204"#, .caseInsensitive)
/// Commands that talk to apps. Only these are compared with the frozen apps:
/// an app's name in a path or in code being edited doesn't mean the app is used.
let talksToApps = regex(#"osascript|(?:^|[;&|(`$]\s*|\n\s*|\bthen\s+|\bdo\s+)open\s|agent-desktop|lsappinfo|screencapture|System Events|Application\(|cliclick|peekaboo|shortcuts run|\bpkill\b|\bkillall\b"#)

/// One line for the agent when a tool call failed while apps were frozen, or
/// nil. Only an app the failure really names is woken: its name as a word with
/// its own capitals in the error (AppleScript says "Notes got an error"), its
/// bundle ID, or the command addressing it. "Retry" is said outright only for an
/// error a frozen app causes (a timed-out Apple event); after a plain timeout
/// the agent is told to retry if the command needed that app.
func hintAfterFailure(owner: pid_t) -> String? {
    guard !frozen.isEmpty else { return nil }
    let failed = event.lowercased() == "posttoolusefailure"
    let response = json["tool_response"] as? [String: Any]
    let output = (json["error"] as? String)
        ?? [response?["stdout"], response?["stderr"]].compactMap { $0 as? String }.joined(separator: "\n")
    let text = String(output.prefix(20_000))
    let call = command ?? strings(in: input).map(\.value).joined(separator: " ")
    let strong = contains(strongSymptom, text), hang = contains(symptom, text)
    guard failed ? (hang || contains(talksToApps, call)) : strong else { return nil }

    let named = frozen.filter { app in
        if app.bundle.contains("."), contains(regex(#"(?<![\w.-])\#(NSRegularExpression.escapedPattern(for: app.bundle))(?![\w-])"#, .caseInsensitive), text) { return true }
        guard app.name.count >= 2, !notApps.contains(app.name), text.contains(app.name) else { return false }
        return contains(regex(#"(?<![\w-])\#(NSRegularExpression.escapedPattern(for: app.name))(?![\w-])"#), text)
    } + frozenApps(namedIn: call, loose: false).filter { app in !text.contains(app.name) }
    if hang || strong, !named.isEmpty {
        for app in named { need(app.bundle, owner: owner) }
        let names = named.map(\.name).joined(separator: ", ")
        let one = named.count == 1
        return "Maben Awake: \(names) \(one ? "was" : "were") frozen and \(one ? "is" : "are") awake now (10 min). "
            + (strong ? "Retry the command." : "If the command needed \(one ? "it" : "them"), retry it.")
    }
    let names = frozen.prefix(8).map(\.name).joined(separator: ", ") + (frozen.count > 8 ? " and \(frozen.count - 8) more" : "")
    return "Maben Awake: these apps are frozen: \(names). If the command needed one, run `awake need \"<App>\"` and retry."
}

/// The same hint at most once every 10 minutes per session.
func isRepeat(_ hint: String, lease name: String) -> Bool {
    let path = leaseDir + "/.hint-" + safe(name)
    let now = Int(Date().timeIntervalSince1970)
    if let text = try? String(contentsOfFile: path, encoding: .utf8),
       let space = text.firstIndex(of: " "), let then = Int(text[..<space]),
       now - then < 600, text[text.index(after: space)...] == hint { return true }
    try? "\(now) \(hint)".write(toFile: path, atomically: true, encoding: .utf8)
    return false
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

/// Wakes the apps a tool call names: by the patterns above, and any frozen app it names.
func wakeApps(for owner: pid_t) {
    var apps = Set<String>()
    if isShell, let command {
        // A frozen app found by both goes by its bundle ID only. Heredocs are
        // mostly code being written to a file, unless they are fed to osascript.
        let spoken = command.range(of: #"osascript[^\n;&|]*<<"#, options: .regularExpression) != nil ? command : withoutHeredocs(command)
        let named = contains(talksToApps, spoken) ? frozenApps(namedIn: spoken, loose: false) : []
        let more = moreAppsMentioned(in: spoken).compactMap { want in want == "browser" ? (frozenApp(want) != nil ? want : nil) : frozenApp(want)?.bundle }
        apps = appsMentioned(in: command).subtracting(named.map(\.name)).union(named.map(\.bundle)).union(more)
    } else if tool.lowercased().contains("mcp") || tool.lowercased().contains("computer") {
        apps = appsInArguments()
    }
    for app in apps { need(app, owner: owner) }
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
        // Claude Code says at the end of the turn whether it is still running (see Stop below).
        if isShell, ["run_in_background", "is_background", "background"].contains(where: { input[$0] as? Bool == true }) {
            hold(name + "-bg", minutes: 30, owner: owner)
        } else if isShell, let command, detaches(command) {
            // Nothing reports when a detached process ends: an hour, like a background command's first lease.
            hold(name + "-detached", minutes: 60, owner: owner)
        }
    }

    // Wake the apps this tool call is about to use.
    let lower = tool.lowercased()
    if lower.contains("chrome") || lower.contains("browser") || lower.contains("playwright") || lower.contains("preview_") {
        need("browser", owner: owner)
    }
    wakeApps(for: owner)
}

// Cursor only reports a tool once it has finished (see Integration.swift), so the
// apps a command names are woken then: in time for the agent's next try.
if agent == "cursor", kind == .toolEnd, isShell, let command {
    for app in appsMentioned(in: command) { need(app, owner: owner) }
}

// Claude Code reads a hook's answer after a tool call; every other agent gets
// nothing, since some take any output for a decision.
var answer: String? = nil
if agent == "claude", kind == .toolEnd, let hint = hintAfterFailure(owner: owner), !isRepeat(hint, lease: name) {
    answer = hint
}

switch kind {
case .stop:
    release(name)
    releaseMatching(prefix: "need-", suffix: "-\(owner)")
    // Claude Code lists the background work still running when a turn ends,
    // and ends another turn when it finishes: hold until then, at most 8 hours
    // after the last turn. Without the list, the lease from the tool call stands.
    if let tasks = json["background_tasks"] as? [[String: Any]] {
        let running = tasks.contains { !finished.contains(($0["status"] as? String ?? "running").lowercased()) }
        if running { hold(name + "-bg", minutes: 480, owner: owner) } else { release(name + "-bg") }
    }
case .sessionEnd:
    release(name)
    releaseMatching(prefix: name + "-")
    releaseMatching(prefix: ".hint-" + name)
    releaseMatching(prefix: "need-", suffix: "-\(owner)")
case .toolStart:
    // A tool can run long (builds), so hold 2 h while one runs; between tools
    // 15 min is plenty and limits a stale lease if Stop is ever missed.
    hold(name, minutes: 120, owner: owner)
default:
    // Cursor doesn't say when a tool starts, so its hold has to cover a long tool from the start.
    hold(name, minutes: agent == "cursor" ? 120 : 15, owner: owner)
}

if let answer {
    let reply: [String: Any] = ["hookSpecificOutput": ["hookEventName": event, "additionalContext": answer]]
    if let out = try? JSONSerialization.data(withJSONObject: reply) {
        FileHandle.standardOutput.write(out + Data("\n".utf8))
    }
}
exit(0)   // otherwise prints nothing: no agent takes that for a decision
