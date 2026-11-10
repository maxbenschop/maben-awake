#!/bin/sh
# Tests the hook and `awake` installer (Sources/MabenAwake/Integration.swift)
# against a temporary home folder. Touches nothing real.
set -e
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src" "$T/home/.claude" "$T/home/.claude-work" "$T/home/.claude-plain" "$T/bin" "$T/App.app/Contents/Resources" "$T/App.app/Contents/MacOS"
cp Sources/MabenAwake/Integration.swift "$T/src/"
cat > "$T/src/main.swift" <<'SWIFT'
import Foundation
enum Failsafe { static func shellQuote(_ s: String) -> String { "'" + s + "'" } }
enum Legacy { static let hookName = "sleepwalker-hook" }
let a = CommandLine.arguments
Integration.home = URL(fileURLWithPath: a[1])
Integration.bundle = URL(fileURLWithPath: a[2])
Integration.cliCandidates = [a[3] + "/awake"]
var failed = 0
func check(_ name: String, _ ok: Bool) { print(ok ? "ok   " : "FAIL ", name); if !ok { failed += 1 } }
func json(_ p: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(contentsOf: Integration.home.appendingPathComponent(p)))) as? [String: Any] ?? [:]
}
func commands(_ p: String, _ event: String) -> [String] {
    let groups = (json(p)["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
}
let mine = "\"" + Integration.hookPath + "\""

check("starts outdated (old app path present)", Integration.hooksStatus == .outdated)
let written = try Integration.installHooks()
check("writes main and the folder that had hooks, not the plain one", written.map(\.lastPathComponent).count == 2
      && !FileManager.default.fileExists(atPath: a[1] + "/.claude-plain/settings.json.before-maben-awake"))
check("status installed", Integration.hooksStatus == .installed)
for event in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"] {
    check("main has exactly one own hook for \(event)", commands(".claude/settings.json", event).filter { $0.contains("maben-awake-hook") } == [mine])
}
check("old app path is gone", !commands(".claude/settings.json", "PreToolUse").contains { $0.contains("Sleepwalker.app") })
check("other hook kept", commands(".claude/settings.json", "PreToolUse").contains("echo other"))
check("other settings kept", json(".claude/settings.json")["model"] as? String == "opus" && (json(".claude/settings.json")["permissions"] as? [String: Any]) != nil)
check("tool hooks have a matcher", ((json(".claude/settings.json")["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.last?["matcher"] as? String == "")
check("backup made once", FileManager.default.fileExists(atPath: a[1] + "/.claude/settings.json.before-maben-awake"))
try Integration.installHooks()
check("installing twice doesn't duplicate", commands(".claude/settings.json", "Stop").filter { $0 == mine }.count == 1)
check("second folder moved to this copy", commands(".claude-work/settings.json", "Stop") == [mine])

try "{ not json".write(toFile: a[1] + "/.claude-plain/settings.json", atomically: true, encoding: .utf8)
try FileManager.default.createDirectory(atPath: a[1] + "/.claude-bad", withIntermediateDirectories: true)
try "{ \"hooks\": maben-awake-hook broken".write(toFile: a[1] + "/.claude-bad/settings.json", atomically: true, encoding: .utf8)
var threw = false
do { try Integration.installHooks() } catch { threw = true; print("     (message: \(error.localizedDescription))") }
check("a broken settings file is reported and left alone", threw
      && (try! String(contentsOfFile: a[1] + "/.claude-bad/settings.json", encoding: .utf8)) == "{ \"hooks\": maben-awake-hook broken")
try FileManager.default.removeItem(atPath: a[1] + "/.claude-bad")

try Integration.removeHooks()
check("remove: no own hooks left", Integration.hooksStatus == .missing)
check("remove: other hook kept", commands(".claude/settings.json", "PreToolUse") == ["echo other"])
check("remove: empty events dropped", (json(".claude/settings.json")["hooks"] as? [String: Any])?["Stop"] == nil)
check("remove: file with only our hooks has no hooks key", json(".claude-work/settings.json")["hooks"] == nil)

// Codex: ~/.codex/hooks.json, kept apart from Claude Code's settings
try FileManager.default.createDirectory(atPath: a[1] + "/.codex", withIntermediateDirectories: true)
try #"{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo mine" } ] } ] } }"#.write(toFile: a[1] + "/.codex/hooks.json", atomically: true, encoding: .utf8)
check("codex missing", Integration.codexStatus == .missing)
try Integration.installCodexHooks()
check("codex installed", Integration.codexStatus == .installed)
check("codex hook has --agent codex", commands(".codex/hooks.json", "Stop").contains(mine.replacingOccurrences(of: "\"\n", with: "") + " --agent codex"))
check("codex keeps other hook", commands(".codex/hooks.json", "Stop").contains("echo mine"))
check("codex has Interrupt", commands(".codex/hooks.json", "Interrupt").count == 1)
try Integration.installCodexHooks()
check("codex install twice doesn't duplicate", commands(".codex/hooks.json", "PreToolUse").count == 1)
check("claude hooks untouched by codex", Integration.hooksStatus == .missing)
try Integration.removeCodexHooks()
check("codex removed, other hook kept", Integration.codexStatus == .missing && commands(".codex/hooks.json", "Stop") == ["echo mine"])

// The other agents (Integration.agents)
func text(_ p: String) -> String { (try? String(contentsOf: Integration.home.appendingPathComponent(p), encoding: .utf8)) ?? "" }
func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: a[1] + "/" + p) }
func put(_ p: String, _ t: String) {
    let url = Integration.home.appendingPathComponent(p)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! t.write(to: url, atomically: true, encoding: .utf8)
}
check("only agents set up on this Mac are listed", Integration.presentAgents.map(\.id) == ["codex"])
for folder in [".cursor", ".gemini", ".copilot", ".config/opencode", ".qwen", ".factory", ".config/devin", ".augment", ".kiro"] {
    try FileManager.default.createDirectory(atPath: a[1] + "/" + folder, withIntermediateDirectories: true)
}
check("every agent listed once its folder exists", Integration.presentAgents.count == Integration.agents.count)

// Cursor: a flat list of commands per event, next to "version"
put(".cursor/hooks.json", #"{ "version": 1, "hooks": { "stop": [ { "command": "echo mine" } ] } }"#)
let cursor = Integration.agent("cursor")
try Integration.install(cursor); try Integration.install(cursor)
let cursorHooks = json(".cursor/hooks.json")["hooks"] as? [String: [[String: Any]]] ?? [:]
check("cursor installed, once, with its own event names", Integration.status(of: cursor) == .installed
      && cursorHooks["postToolUse"]?.compactMap { $0["command"] as? String } == [mine + " --agent cursor --event postToolUse"]
      && cursorHooks["beforeSubmitPrompt"]?.count == 1 && json(".cursor/hooks.json")["version"] as? Int == 1)
check("cursor gets no hook that could block or approve a tool call", cursorHooks["preToolUse"] == nil && cursorHooks["beforeShellExecution"] == nil)
check("cursor keeps other hook", cursorHooks["stop"]?.compactMap { $0["command"] as? String } == ["echo mine", mine + " --agent cursor --event stop"])
try Integration.remove(cursor)
check("cursor removed, other hook kept", Integration.status(of: cursor) == .missing
      && (json(".cursor/hooks.json")["hooks"] as? [String: [[String: Any]]])?.keys.sorted() == ["stop"])

// Gemini CLI, Qwen Code, Devin, Augment: Claude Code's layout in their own settings, with their own event names
for (id, file, prompt, turnEnd) in [("gemini", ".gemini/settings.json", "BeforeAgent", "AfterAgent"), ("qwen", ".qwen/settings.json", "UserPromptSubmit", "Stop"),
                                    ("devin", ".config/devin/config.json", "UserPromptSubmit", "Stop"), ("auggie", ".augment/settings.json", "PromptSubmit", "Stop")] {
    put(file, #"{ "theme": "dark", "hooks": { "SessionEnd": [ { "hooks": [ { "type": "command", "command": "echo mine" } ] } ] } }"#)
    let agent = Integration.agent(id)
    try Integration.install(agent); try Integration.install(agent)
    check("\(id) installed, once", Integration.status(of: agent) == .installed
          && commands(file, prompt) == [mine + " --agent \(id) --event \(prompt)"] && commands(file, turnEnd).count == 1)
    check("\(id) keeps other hook and settings", commands(file, "SessionEnd").first == "echo mine" && json(file)["theme"] as? String == "dark")
    try Integration.remove(agent)
    check("\(id) removed, other hook kept", Integration.status(of: agent) == .missing && commands(file, "SessionEnd") == ["echo mine"]
          && (json(file)["hooks"] as? [String: Any])?.count == 1)
}
check("tool hooks match every tool", ({ try! Integration.install(Integration.agent("gemini"))
      return ((json(".gemini/settings.json")["hooks"] as? [String: Any])?["BeforeTool"] as? [[String: Any]])?.last?["matcher"] as? String == ".*" })())

// Droid: hooks.json (events at the top level), unless its settings already hold hooks
let droid = Integration.agent("droid")
try Integration.install(droid)
check("droid: hooks.json created with events at the top level", Integration.status(of: droid) == .installed
      && (json(".factory/hooks.json")["Stop"] as? [[String: Any]])?.count == 1 && json(".factory/hooks.json")["hooks"] == nil)
try Integration.remove(droid)
check("droid: removing deletes the hooks.json it made", !exists(".factory/hooks.json") && Integration.status(of: droid) == .missing)
put(".factory/settings.json", #"{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo mine" } ] } ] } }"#)
try Integration.install(droid)
check("droid: uses settings.json when that has hooks (hooks.json would hide them)", !exists(".factory/hooks.json")
      && commands(".factory/settings.json", "Stop") == ["echo mine", mine + " --agent droid --event Stop"])
try Integration.remove(droid)
check("droid: removed from settings.json, other hook kept", commands(".factory/settings.json", "Stop") == ["echo mine"])

// Copilot, Kiro, OpenCode: a file of our own
for (id, file) in [("copilot", ".copilot/hooks/maben-awake.json"), ("kiro", ".kiro/hooks/maben-awake.json"), ("opencode", ".config/opencode/plugins/maben-awake.js")] {
    let agent = Integration.agent(id)
    try Integration.install(agent)
    check("\(id): own file written", Integration.status(of: agent) == .installed && text(file).contains(Integration.hookPath))
    if id != "opencode" { check("\(id): file is valid JSON", !json(file).isEmpty) }
    put(file, text(file).replacingOccurrences(of: Integration.hookPath, with: "/Applications/Sleepwalker.app/Contents/MacOS/sleepwalker-hook"))
    check("\(id): pointing at another copy is outdated", Integration.status(of: agent) == .outdated)
    try Integration.remove(agent)
    check("\(id): removing deletes the file", !exists(file) && Integration.status(of: agent) == .missing)
}
try Integration.install(Integration.agent("copilot"))
check("copilot: a missing app never fails a tool call", ((json(".copilot/hooks/maben-awake.json")["hooks"] as? [String: [[String: Any]]])?["PreToolUse"]?.first?["bash"] as? String)?.hasSuffix("|| true") == true)
try Integration.install(Integration.agent("kiro"))
check("kiro: five named hooks", (json(".kiro/hooks/maben-awake.json")["hooks"] as? [[String: Any]])?.compactMap { $0["trigger"] as? String }
      == ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"])
put(".gemini/settings.json", "{ // comment\n \"hooks\": {} }")
threw = false
do { try Integration.install(Integration.agent("gemini")) } catch { threw = true }
check("a settings file with comments is reported and left alone", threw && text(".gemini/settings.json").hasPrefix("{ // comment"))
check("claude hooks untouched by the other agents", Integration.hooksStatus == .missing)
check("lease names map to agents", Integration.agentName(ofLease: "gemini-abc") == "Gemini CLI" && Integration.agentName(ofLease: "claude-abc") == "Claude"
      && Integration.agentName(ofLease: "build") == nil)

// Updated from 1.4: connections call this copy's hook by its old name
let oldName = "\"" + a[2] + "/Contents/MacOS/sleepwalker-hook\""
func putJSON(_ p: String, _ object: Any) { put(p, String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)) }
putJSON(".claude/settings.json", ["hooks": ["Stop": [["hooks": [["type": "command", "command": oldName]]]]]])
putJSON(".cursor/hooks.json", ["version": 1, "hooks": ["stop": [["command": oldName + " --agent cursor --event stop"]]]])
putJSON(".qwen/settings.json", ["hooks": ["Stop": [["hooks": [["type": "command", "command": "\"/Applications/Sleepwalker.app/Contents/MacOS/sleepwalker-hook\" --agent qwen"]]]]]])
check("old hook name counts as connected but outdated", Integration.hooksStatus == .outdated && Integration.status(of: cursor) == .outdated)
Integration.moveFromOldHookName()
check("not moved while the app is outside Applications", Integration.hooksStatus == .outdated)
let realBundle = Integration.bundle
try FileManager.default.createDirectory(atPath: a[1] + "/Applications", withIntermediateDirectories: true)
try FileManager.default.createSymbolicLink(atPath: a[1] + "/Applications/App.app", withDestinationPath: a[2])
let inApplications = "\"" + a[1] + "/Applications/App.app/Contents/MacOS/sleepwalker-hook\""
putJSON(".claude/settings.json", ["hooks": ["Stop": [["hooks": [["type": "command", "command": inApplications]]]]]])
putJSON(".cursor/hooks.json", ["version": 1, "hooks": ["stop": [["command": inApplications + " --agent cursor --event stop"]]]])
Integration.bundle = URL(fileURLWithPath: a[1] + "/Applications/App.app")
Integration.moveFromOldHookName()
check("connections to this copy move to the new hook name", Integration.hooksStatus == .installed && Integration.status(of: cursor) == .installed
      && commands(".claude/settings.json", "Stop") == ["\"" + Integration.hookPath + "\""] && !text(".cursor/hooks.json").contains("sleepwalker-hook"))
check("a connection to another copy is left alone", Integration.status(of: Integration.agent("qwen")) == .outdated)
try Integration.removeHooks(); try Integration.remove(cursor); try Integration.remove(Integration.agent("qwen"))
check("the old hook name is removed too", Integration.hooksStatus == .missing && !text(".qwen/settings.json").contains("sleepwalker-hook"))
Integration.bundle = realBundle

check("cli missing", Integration.cliStatus == .missing)
let sem = DispatchSemaphore(value: 0)
Integration.installCLI { ok in check("cli installed without a password in a writable folder", ok && Integration.cliStatus == .installed); sem.signal() }
while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date() + 0.05) }
try FileManager.default.removeItem(atPath: a[3] + "/awake")
try FileManager.default.createSymbolicLink(atPath: a[3] + "/awake", withDestinationPath: "/Applications/Sleepwalker.app/Contents/Resources/awake")
check("cli pointing at another copy is outdated", Integration.cliStatus == .outdated)
Integration.removeCLI { ok in check("cli removed", ok && Integration.cliStatus == .missing); sem.signal() }
while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date() + 0.05) }
print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
SWIFT
OLD='"/Applications/Sleepwalker.app/Contents/MacOS/sleepwalker-hook"'
cat > "$T/home/.claude/settings.json" <<JSON
{
  "model": "opus",
  "permissions": { "allow": ["Bash(ls:*)"] },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo other" } ] },
      { "matcher": "", "hooks": [ { "type": "command", "command": "\"/Applications/Sleepwalker.app/Contents/MacOS/sleepwalker-hook\"" } ] }
    ],
    "Stop": [ { "hooks": [ { "type": "command", "command": "\"/Applications/Sleepwalker.app/Contents/MacOS/sleepwalker-hook\"" } ] } ]
  }
}
JSON
cat > "$T/home/.claude-work/settings.json" <<JSON
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "\"/Applications/Sleepwalker.app/Contents/MacOS/sleepwalker-hook\"" } ] } ] } }
JSON
echo '{ "theme": "dark" }' > "$T/home/.claude-plain/settings.json"
touch "$T/App.app/Contents/Resources/awake"
swiftc -O -o "$T/test" "$T/src/Integration.swift" "$T/src/main.swift" 2>&1 | grep -v "warning" || true
"$T/test" "$T/home" "$T/App.app" "$T/bin"
