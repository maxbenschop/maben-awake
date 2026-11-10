import AppKit

/// What connects AI tools to the app: the hooks of Claude Code and of the
/// other agents (`agents`), and the `awake` command. Settings → Agents shows
/// whether they are in place and installs, updates or removes them.
/// (`build.sh install` does the same for Claude Code and Codex in a
/// development build.)
enum Integration {
    enum Status { case missing, outdated, installed }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Home folder; a variable so the tests can point it at a temporary folder.
    static var home = FileManager.default.homeDirectoryForCurrentUser
    /// The app bundle the hooks and the command should point at.
    static var bundle = Bundle.main.bundleURL

    static var hooksLog: URL { home.appendingPathComponent("Library/Logs/MabenAwake-hooks.log") }

    /// Hooks and the command hold the app's path, so they are only installed
    /// from a copy that stays put. A copy opened straight from Downloads runs
    /// from a temporary, read-only location that macOS picks ("translocation").
    static var isInApplications: Bool {
        let path = bundle.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home.appendingPathComponent("Applications").path + "/")
    }

    // MARK: Claude Code hooks

    static var hookPath: String { bundle.appendingPathComponent("Contents/MacOS/maben-awake-hook").path }
    private static var hookCommand: String { "\"\(hookPath)\"" }
    private static let hookEvents = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"]
    /// The hook's file name, now and before 1.5.
    private static let hookNames = ["maben-awake-hook", Legacy.hookName]
    /// Commands written by this app under any of its names, or by its old shell hook.
    private static let ownMarkers = hookNames + ["AwakeKeeper.app", "Sleepwalker.app/Contents/Resources/awake"]

    private static func isOwn(_ command: String) -> Bool { ownMarkers.contains { command.contains($0) } }
    private static func callsHook(_ text: String) -> Bool { hookNames.contains { text.contains($0) } }

    /// After updating from 1.4 or earlier, every connection still calls this
    /// copy's hook by its old name (kept as a link in the app). Moves them to
    /// the current name; connections to another copy of the app are left alone.
    static func moveFromOldHookName() {
        guard isInApplications else { return }
        let old = bundle.appendingPathComponent("Contents/MacOS/" + Legacy.hookName).path
        func pointsAtOld(_ url: URL) -> Bool {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains(old) || text.contains(old.replacingOccurrences(of: "/", with: "\\/"))
        }
        if hookedSettingsFiles.contains(where: pointsAtOld) { _ = try? installHooks() }
        for agent in agents where files(of: agent).contains(where: pointsAtOld) { try? install(agent) }
    }

    /// Every Claude Code settings file (`~/.claude*/settings.json`).
    private static var settingsFiles: [URL] {
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return dirs.filter { $0.hasPrefix(".claude") }.sorted().map {
            home.appendingPathComponent($0).appendingPathComponent("settings.json")
        }
    }

    /// Claude Code settings files that call the hook (of any copy of the app).
    static var hookedSettingsFiles: [URL] {
        settingsFiles.filter { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return callsHook(text)
        }
    }

    static var hooksStatus: Status {
        let hooked = hookedSettingsFiles
        if hooked.isEmpty { return .missing }
        // JSON may or may not escape the slashes in the path.
        let escaped = hookPath.replacingOccurrences(of: "/", with: "\\/")
        let current = hooked.allSatisfy { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains(hookPath) || text.contains(escaped)
        }
        return current ? .installed : .outdated
    }

    /// Adds the hooks to `~/.claude/settings.json`, and moves any other Claude
    /// Code config folder that already had them to this copy of the app.
    /// Everything else in those files is kept. Returns the files written.
    @discardableResult
    static func installHooks() throws -> [URL] {
        let main = home.appendingPathComponent(".claude/settings.json")
        let targets = [main] + hookedSettingsFiles.filter { $0 != main }
        for url in targets {
            var settings = try read(url)
            var hooks = settings["hooks"] as? [String: Any] ?? [:]
            for event in hookEvents {
                var groups = strip(hooks[event] as? [[String: Any]] ?? [])
                let entry: [String: Any] = ["type": "command", "command": hookCommand]
                groups.append(event.hasSuffix("ToolUse") ? ["matcher": "", "hooks": [entry]] : ["hooks": [entry]])
                hooks[event] = groups
            }
            settings["hooks"] = hooks
            try write(settings, to: url)
        }
        return targets
    }

    /// Removes the hooks from every Claude Code settings file. Returns the files changed.
    @discardableResult
    static func removeHooks() throws -> [URL] {
        let targets = settingsFiles.filter { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return isOwn(text)
        }
        for url in targets {
            var settings = try read(url)
            guard var hooks = settings["hooks"] as? [String: Any] else { continue }
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                let kept = strip(groups)
                if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
            }
            if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
            try write(settings, to: url)
        }
        return targets
    }

    /// The hook groups without this app's commands; groups left empty are dropped.
    private static func strip(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            guard let entries = group["hooks"] as? [[String: Any]] else { return group }
            let kept = entries.filter { !isOwn($0["command"] as? String ?? "") }
            if kept.isEmpty { return nil }
            var group = group
            group["hooks"] = kept
            return group
        }
    }

    private static func read(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }      // no file yet
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data), let settings = object as? [String: Any] else {
            // Never overwrite a file we can't read back.
            throw Failure(message: "\(tilde(url)) isn't valid JSON, so it was left alone. Fix it and try again.")
        }
        return settings
    }

    private static func write(_ settings: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // One copy of the file as it was before this app first touched it.
            let backup = url.appendingPathExtension("before-maben-awake")
            if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: url, to: backup) }
            var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            data.append(0x0A)
            try data.write(to: url, options: .atomic)
        } catch {
            throw Failure(message: "Couldn't write \(tilde(url)): \(error.localizedDescription)")
        }
    }

    static func tilde(_ url: URL) -> String {
        url.path.hasPrefix(home.path + "/") ? "~" + url.path.dropFirst(home.path.count) : url.path
    }

    // MARK: Other agents

    /// An AI agent other than Claude Code that can call the hook.
    struct Agent: Identifiable {
        /// How the agent's config file holds its hooks.
        enum Layout {
            /// Claude Code's layout: `hooks.<Event>` is a list of groups, each with its own `hooks` list.
            case groups
            /// Cursor's layout: `hooks.<event>` is a list of commands, next to a `version`.
            case entries
            /// A file of our own in the agent's hooks or plugins folder, written whole and deleted to remove.
            case ownFile((_ hook: String) -> String)
        }

        /// Lease prefix and the hook's `--agent` value.
        let id: String
        let name: String
        /// Folder (from the home folder) that exists once the agent is set up on this Mac.
        let folder: String
        /// Config file (from the home folder) the hooks go in.
        let file: String
        let layout: Layout
        /// The agent's names for: prompt sent, tool starts, tool finished, turn ended, session closed.
        var events: [String] = []
        /// Events about a tool, which get a match-everything matcher.
        var toolEvents: Set<String> = []
        /// What's left to do after connecting, if anything.
        var afterConnecting: String? = nil
        /// Run for real with the agent itself. The others are built from the agent's
        /// documentation only (they need an account), and Settings says so.
        var tested = true
    }

    static let agents: [Agent] = [
        // Codex has `hook_event_name` in its JSON, and installs from before 1.5 have no `--event`.
        Agent(id: "codex", name: "Codex", folder: ".codex", file: ".codex/hooks.json", layout: .groups,
              events: ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Interrupt", "SessionEnd"],
              afterConnecting: "Run /hooks in Codex once to trust them."),
        // No preToolUse: Cursor blocks a tool call whose hook answers anything but a valid decision,
        // and a hook that answers "allow" has not been tried against Cursor's own approval prompts.
        Agent(id: "cursor", name: "Cursor", folder: ".cursor", file: ".cursor/hooks.json", layout: .entries,
              events: ["beforeSubmitPrompt", "postToolUse", "stop", "sessionEnd"], tested: false),
        Agent(id: "gemini", name: "Gemini CLI", folder: ".gemini", file: ".gemini/settings.json", layout: .groups,
              events: ["BeforeAgent", "BeforeTool", "AfterTool", "AfterAgent", "SessionEnd"],
              toolEvents: ["BeforeTool", "AfterTool"], afterConnecting: "Works from the next Gemini CLI session."),
        Agent(id: "copilot", name: "GitHub Copilot", folder: ".copilot", file: ".copilot/hooks/maben-awake.json",
              layout: .ownFile(copilotFile), afterConnecting: "Works from the next Copilot session, in the terminal and in VS Code."),
        Agent(id: "opencode", name: "OpenCode", folder: ".config/opencode", file: ".config/opencode/plugins/maben-awake.js",
              layout: .ownFile(openCodePlugin), afterConnecting: "Works from the next OpenCode session."),
        Agent(id: "qwen", name: "Qwen Code", folder: ".qwen", file: ".qwen/settings.json", layout: .groups,
              events: ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "StopFailure", "SessionEnd"],
              toolEvents: ["PreToolUse", "PostToolUse"], afterConnecting: "Works from the next Qwen Code session."),
        // Droid reads ~/.factory/hooks.json, or the hooks in its settings.json when that file is missing: see `file(of:)`.
        Agent(id: "droid", name: "Droid", folder: ".factory", file: ".factory/hooks.json", layout: .groups,
              events: ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Notification", "SessionEnd"],
              toolEvents: ["PreToolUse", "PostToolUse"], afterConnecting: "Works from the next Droid session.", tested: false),
        Agent(id: "devin", name: "Devin", folder: ".config/devin", file: ".config/devin/config.json", layout: .groups,
              events: ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"],
              toolEvents: ["PreToolUse", "PostToolUse"], afterConnecting: "Works from the next Devin session.", tested: false),
        Agent(id: "auggie", name: "Augment", folder: ".augment", file: ".augment/settings.json", layout: .groups,
              events: ["PromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"],
              toolEvents: ["PreToolUse", "PostToolUse"], afterConnecting: "Works from the next Augment session.", tested: false),
        Agent(id: "kiro", name: "Kiro", folder: ".kiro", file: ".kiro/hooks/maben-awake.json",
              layout: .ownFile(kiroFile), afterConnecting: "Works from the next Kiro CLI session.", tested: false),
    ]

    static func agent(_ id: String) -> Agent { agents.first { $0.id == id }! }

    /// The agent a lease belongs to (leases are named `<agent>-<session>`), if any.
    static func agentName(ofLease name: String) -> String? {
        if name.hasPrefix("claude-") { return "Claude" }
        return agents.first { name.hasPrefix($0.id + "-") }?.name
    }

    /// The agent is set up on this Mac (it has made its config folder).
    static func isPresent(_ agent: Agent) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(agent.folder).path)
    }

    /// Agents set up on this Mac, and the ones that still have our hooks.
    static var presentAgents: [Agent] { agents.filter { isPresent($0) || status(of: $0) != .missing } }

    private static func command(for agent: Agent, event: String) -> String {
        agent.id == "codex" ? "\"\(hookPath)\" --agent codex" : "\"\(hookPath)\" --agent \(agent.id) --event \(event)"
    }

    /// Every file the agent may read its hooks from.
    private static func files(of agent: Agent) -> [URL] {
        var files = [home.appendingPathComponent(agent.file)]
        if agent.id == "droid" { files.append(home.appendingPathComponent(".factory/settings.json")) }
        return files
    }

    /// The file the hooks are written to. Droid ignores the hooks in its
    /// settings once hooks.json exists, so that file is only created when the
    /// settings have no hooks of their own.
    static func file(of agent: Agent) -> URL {
        let all = files(of: agent)
        guard agent.id == "droid", !FileManager.default.fileExists(atPath: all[0].path),
              let settings = try? read(all[1]), settings["hooks"] != nil else { return all[0] }
        return all[1]
    }

    /// Droid's hooks.json has the events at the top level; everywhere else they are under `hooks`.
    private static func isBare(_ url: URL) -> Bool { url.path.hasSuffix(".factory/hooks.json") }

    static func status(of agent: Agent) -> Status {
        let texts = files(of: agent).compactMap { try? String(contentsOf: $0, encoding: .utf8) }.filter(callsHook)
        if texts.isEmpty { return .missing }
        // JSON may or may not escape the slashes in the path.
        let escaped = hookPath.replacingOccurrences(of: "/", with: "\\/")
        return texts.allSatisfy { $0.contains(hookPath) || $0.contains(escaped) } ? .installed : .outdated
    }

    static func install(_ agent: Agent) throws {
        try remove(agent)   // also from a file it is no longer read from
        let url = file(of: agent)
        if case .ownFile(let contents) = agent.layout {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents(hookPath).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw Failure(message: "Couldn't write \(tilde(url)): \(error.localizedDescription)")
            }
            return
        }
        var settings = try read(url)
        var hooks = isBare(url) ? settings : settings["hooks"] as? [String: Any] ?? [:]
        for event in agent.events {
            var list = hooks[event] as? [[String: Any]] ?? []
            let command = command(for: agent, event: event)
            if case .entries = agent.layout {
                list.append(["command": command])
            } else {
                var group: [String: Any] = ["hooks": [["type": "command", "command": command]]]
                if agent.toolEvents.contains(event) { group["matcher"] = ".*" }
                list.append(group)
            }
            hooks[event] = list
        }
        if isBare(url) {
            settings = hooks
        } else {
            settings["hooks"] = hooks
            if case .entries = agent.layout, settings["version"] == nil { settings["version"] = 1 }
        }
        try write(settings, to: url)
    }

    static func remove(_ agent: Agent) throws {
        for url in files(of: agent) {
            guard let text = try? String(contentsOf: url, encoding: .utf8), isOwn(text) else { continue }
            if case .ownFile = agent.layout {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            var settings = try read(url)
            var hooks = isBare(url) ? settings : settings["hooks"] as? [String: Any] ?? [:]
            for (event, value) in hooks {
                guard let list = value as? [[String: Any]] else { continue }
                let kept: [[String: Any]]
                if case .entries = agent.layout {
                    kept = list.filter { !isOwn($0["command"] as? String ?? "") }
                } else {
                    kept = strip(list)
                }
                if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
            }
            if isBare(url) {
                // An empty hooks.json would still make Droid skip the hooks in its settings.
                if hooks.isEmpty { try? FileManager.default.removeItem(at: url); continue }
                settings = hooks
            } else if hooks.isEmpty {
                settings.removeValue(forKey: "hooks")
            } else {
                settings["hooks"] = hooks
            }
            try write(settings, to: url)
        }
    }

    private static func jsonText(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Copilot (the CLI, and Copilot sessions in VS Code) reads every file in
    /// ~/.copilot/hooks. It refuses a tool call when a tool hook fails, so
    /// `|| true` keeps it working if the app is ever deleted without removing this file.
    private static func copilotFile(hook: String) -> String {
        var hooks: [String: Any] = [:]
        for event in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"] {
            hooks[event] = [["type": "command", "bash": "\"\(hook)\" --agent copilot --event \(event) || true", "timeoutSec": 10]]
        }
        return jsonText(["version": 1, "hooks": hooks])
    }

    /// Kiro CLI reads every file in ~/.kiro/hooks.
    private static func kiroFile(hook: String) -> String {
        let hooks = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"].map { event -> [String: Any] in
            ["name": "Maben Awake (\(event))", "trigger": event, "timeout": 10,
             "action": ["type": "command", "command": "\"\(hook)\" --agent kiro --event \(event)"]]
        }
        return jsonText(["version": "v1", "hooks": hooks])
    }

    /// OpenCode has plugins instead of hooks: a JavaScript file in its plugins
    /// folder. This one passes each event to the hook in Claude Code's format.
    /// It answers both OpenCode 1 (`server`) and OpenCode 2 (`setup`).
    private static func openCodePlugin(hook: String) -> String {
        """
        // Maben Awake: keeps the Mac awake while OpenCode works (awake.maben.gg).
        // Written by Maben Awake. Remove it in Settings → Agents, or delete this file.
        import { spawn } from "node:child_process"
        import { existsSync } from "node:fs"

        const HOOK = \(jsonText(hook).trimmingCharacters(in: .whitespacesAndNewlines))

        function send(event, sessionID, tool, input) {
          try {
            if (!existsSync(HOOK)) return
            const child = spawn(HOOK, ["--agent", "opencode", "--event", event], { stdio: ["pipe", "ignore", "ignore"] })
            child.on("error", () => {})
            child.stdin.on("error", () => {})
            child.stdin.end(JSON.stringify({ session_id: sessionID ?? "unknown", tool_name: tool ?? "", tool_input: input ?? {} }))
          } catch {}
        }

        function lifecycle(type, sessionID, status) {
          if (type === "session.idle" || type === "session.error" || (type === "session.status" && status === "idle")) send("Stop", sessionID)
          else if (type === "session.execution.succeeded" || type === "session.execution.failed" || type === "session.execution.interrupted") send("Stop", sessionID)
          else if (type === "session.deleted") send("SessionEnd", sessionID)
        }

        export default {
          id: "maben-awake",

          // OpenCode 1
          async server() {
            return {
              "chat.message": async (input) => send("UserPromptSubmit", input?.sessionID),
              "tool.execute.before": async (input, output) => send("PreToolUse", input?.sessionID, input?.tool, { command: output?.args?.command }),
              "tool.execute.after": async (input) => send("PostToolUse", input?.sessionID, input?.tool),
              event: async ({ event }) => {
                const p = event?.properties ?? {}
                lifecycle(event?.type, p.sessionID ?? p.info?.id, p.status?.type)
              },
            }
          },

          // OpenCode 2
          async setup(ctx) {
            await ctx.session.hook("prompt", (e) => send("UserPromptSubmit", e?.sessionID))
            await ctx.tool.hook("execute.before", (e) => send("PreToolUse", e?.sessionID, e?.tool, { command: e?.input?.command, background: e?.input?.background }))
            await ctx.tool.hook("execute.after", (e) => send("PostToolUse", e?.sessionID, e?.tool))
            const stop = new AbortController()
            void (async () => {
              try {
                for await (const event of ctx.event.subscribe({ signal: stop.signal })) {
                  lifecycle(event?.type, event?.data?.sessionID, event?.data?.status?.type)
                }
              } catch {}
            })()
            return () => stop.abort()
          },
        }

        """
    }

    // MARK: Codex hooks (the names older code and tests use)

    static var codexHooksFile: URL { file(of: agent("codex")) }
    static var codexStatus: Status { status(of: agent("codex")) }
    static func installCodexHooks() throws { try install(agent("codex")) }
    static func removeCodexHooks() throws { try remove(agent("codex")) }

    // MARK: `awake` command

    /// Folders on the default PATH, in order of preference.
    static var cliCandidates = ["/opt/homebrew/bin/awake", "/usr/local/bin/awake"]
    static var cliTarget: String { bundle.appendingPathComponent("Contents/Resources/awake").path }

    /// Path of the linked `awake` command, if any.
    static var cliPath: String? {
        cliCandidates.first { (try? FileManager.default.attributesOfItem(atPath: $0)) != nil }
    }

    static var cliStatus: Status {
        guard let path = cliPath else { return .missing }
        let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
        return destination == cliTarget ? .installed : .outdated
    }

    /// Links `awake` into a folder on the PATH. Uses Homebrew's folder when it
    /// exists (no password needed); otherwise `/usr/local/bin`, which asks for
    /// an administrator password once. `completion` runs on the main thread.
    static func installCLI(completion: @escaping @MainActor (Bool) -> Void) {
        let fm = FileManager.default
        for candidate in cliCandidates where fm.isWritableFile(atPath: (candidate as NSString).deletingLastPathComponent) {
            try? fm.removeItem(atPath: candidate)
            if (try? fm.createSymbolicLink(atPath: candidate, withDestinationPath: cliTarget)) != nil {
                Task { @MainActor in completion(true) }
                return
            }
        }
        let link = "/usr/local/bin/awake"
        runAsAdmin("/bin/mkdir -p /usr/local/bin && /bin/ln -sf \(Failsafe.shellQuote(cliTarget)) \(Failsafe.shellQuote(link))",
                   prompt: "Maben Awake wants to add the awake command to /usr/local/bin.") { ok in
            completion(ok && cliStatus == .installed)
        }
    }

    /// Removes every `awake` link that points into a copy of this app.
    static func removeCLI(completion: @escaping @MainActor (Bool) -> Void) {
        let fm = FileManager.default
        var needAdmin: [String] = []
        for candidate in cliCandidates {
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: candidate),
                  destination.hasSuffix(".app/Contents/Resources/awake") else { continue }
            if (try? fm.removeItem(atPath: candidate)) == nil { needAdmin.append(candidate) }
        }
        guard !needAdmin.isEmpty else { Task { @MainActor in completion(true) }; return }
        runAsAdmin("/bin/rm -f " + needAdmin.map(Failsafe.shellQuote).joined(separator: " "),
                   prompt: "Maben Awake wants to remove the awake command.") { ok in completion(ok) }
    }

    /// Runs a shell command as root after a password prompt, in a separate
    /// process so the dialog never blocks the main thread (which watches the lid).
    private static func runAsAdmin(_ command: String, prompt: String, completion: @escaping @MainActor (Bool) -> Void) {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \(quoted(command)) with prompt \(quoted(prompt)) with administrator privileges"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let ok = proc.terminationStatus == 0
            Task { @MainActor in completion(ok) }
        }
        do { try p.run() } catch { Task { @MainActor in completion(false) } }
    }

    // MARK: Finder helpers

    static func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    static func open(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSSound.beep()
        }
    }
}
