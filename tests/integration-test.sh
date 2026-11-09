#!/bin/sh
# Tests the hook and `awake` installer (Sources/Sleepwalker/Integration.swift)
# against a temporary home folder. Touches nothing real.
set -e
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src" "$T/home/.claude" "$T/home/.claude-work" "$T/home/.claude-plain" "$T/bin" "$T/App.app/Contents/Resources" "$T/App.app/Contents/MacOS"
cp Sources/Sleepwalker/Integration.swift "$T/src/"
cat > "$T/src/main.swift" <<'SWIFT'
import Foundation
enum Failsafe { static func shellQuote(_ s: String) -> String { "'" + s + "'" } }
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
    check("main has exactly one own hook for \(event)", commands(".claude/settings.json", event).filter { $0.contains("sleepwalker-hook") } == [mine])
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
try "{ \"hooks\": sleepwalker-hook broken".write(toFile: a[1] + "/.claude-bad/settings.json", atomically: true, encoding: .utf8)
var threw = false
do { try Integration.installHooks() } catch { threw = true; print("     (message: \(error.localizedDescription))") }
check("a broken settings file is reported and left alone", threw
      && (try! String(contentsOfFile: a[1] + "/.claude-bad/settings.json", encoding: .utf8)) == "{ \"hooks\": sleepwalker-hook broken")
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
