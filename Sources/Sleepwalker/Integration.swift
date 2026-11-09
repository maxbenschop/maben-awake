import AppKit

/// The two things that connect AI tools to the app: the Claude Code hooks and
/// the `awake` command. Settings → AI shows whether they are in place and
/// installs, updates or removes them. (`build.sh install` does the same for a
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

    static var hooksLog: URL { home.appendingPathComponent("Library/Logs/Sleepwalker-hooks.log") }

    /// Hooks and the command hold the app's path, so they are only installed
    /// from a copy that stays put. A copy opened straight from Downloads runs
    /// from a temporary, read-only location that macOS picks ("translocation").
    static var isInApplications: Bool {
        let path = bundle.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home.appendingPathComponent("Applications").path + "/")
    }

    // MARK: Claude Code hooks

    static var hookPath: String { bundle.appendingPathComponent("Contents/MacOS/sleepwalker-hook").path }
    private static var hookCommand: String { "\"\(hookPath)\"" }
    private static let hookEvents = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"]
    /// Commands written by this app under any of its names, or by its old shell hook.
    private static let ownMarkers = ["sleepwalker-hook", "AwakeKeeper.app", "Sleepwalker.app/Contents/Resources/awake"]

    private static func isOwn(_ command: String) -> Bool { ownMarkers.contains { command.contains($0) } }

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
            return text.contains("sleepwalker-hook")
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
