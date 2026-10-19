import AppKit

/// Whether the `awake` CLI and the Claude Code hooks that `build.sh install`
/// sets up are in place, for the AI pane in Settings.
enum Integration {
    static let cliCandidates = ["/opt/homebrew/bin/awake", "/usr/local/bin/awake"]
    static let hooksLog = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Sleepwalker-hooks.log")

    /// Path of the linked `awake` command, if any.
    static var cliPath: String? {
        cliCandidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Claude Code settings files (`~/.claude*/settings.json`) that call the Sleepwalker hook.
    static var hookedSettingsFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return dirs.filter { $0.hasPrefix(".claude") }.sorted().compactMap { dir in
            let url = home.appendingPathComponent(dir).appendingPathComponent("settings.json")
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("sleepwalker-hook") else { return nil }
            return url
        }
    }

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
