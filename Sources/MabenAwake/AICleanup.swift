import AppKit

/// Cleans up after an AI is done with an app, while the lid is closed:
/// - the app wasn't running when the AI asked for it -> quit it again
/// - the app was running -> close the browser tabs the AI opened
///
/// Nothing is touched if the lid was opened while the AI was using the app,
/// because then the user may have opened those tabs themselves.
@MainActor
final class AICleanup {
    private struct Session {
        var launchedByAI: Bool
        /// The process that was running when the AI asked; nil if none was.
        var pidBefore: pid_t?
        var tabsBefore: Set<String>?
        var userWasPresent = false
    }

    /// Keyed by the app string from the lease ("Dia", "browser", a bundle ID…).
    private var sessions: [String: Session] = [:]
    /// Apps busy closing tabs; must not be frozen until the script finishes.
    private(set) var busy = Set<pid_t>()
    private let onDone: () -> Void

    init(onDone: @escaping () -> Void) { self.onDone = onDone }

    /// Call on every update. `requested` = app strings with an active lease;
    /// `find` resolves one to a running app.
    func update(requested: Set<String>, lidClosed: Bool,
                find: (String) -> NSRunningApplication?) -> Set<pid_t> {
        if !lidClosed { for key in sessions.keys { sessions[key]?.userWasPresent = true } }

        // New requests: remember the state before the AI touched the app.
        for key in requested where sessions[key] == nil {
            if let app = find(key), !app.isTerminated {
                var session = Session(launchedByAI: false, pidBefore: app.processIdentifier)
                if Self.supportsTabs(app) {
                    session.tabsBefore = []   // filled in asynchronously
                    let name = app.localizedName ?? ""
                    Self.tabIDs(app: name) { [weak self] ids in
                        if let ids { self?.sessions[key]?.tabsBefore = ids } else { self?.sessions[key]?.tabsBefore = nil }
                    }
                }
                sessions[key] = session
            } else {
                sessions[key] = Session(launchedByAI: true, pidBefore: nil)
            }
        }

        // Finished requests: clean up. Returns pids that must stay awake this round.
        var keepAwake = Set<pid_t>()
        for (key, session) in sessions where !requested.contains(key) {
            sessions[key] = nil
            guard lidClosed, !session.userWasPresent, let app = find(key) else { continue }
            // Another request (e.g. "browser" and "Dia") still uses this app.
            if requested.contains(where: { find($0)?.processIdentifier == app.processIdentifier }) { continue }
            // The app that was open when the AI asked has since quit and this is a
            // new instance (e.g. it was shutting down): the AI launched this one.
            let relaunched = session.pidBefore.map { $0 != app.processIdentifier } ?? false
            // A build the AI is working on (outside /Applications) is never quit:
            // relaunching it isn't a request to clean up after.
            if Policy.isDevBuild(app.bundleURL) { continue }
            if session.launchedByAI || relaunched {
                keepAwake.insert(app.processIdentifier)
                app.terminate()
            } else if let before = session.tabsBefore, Self.supportsTabs(app) {
                let pid = app.processIdentifier
                busy.insert(pid); keepAwake.insert(pid)
                Self.closeTabs(app: app.localizedName ?? "", except: before) { [weak self] in
                    self?.busy.remove(pid)
                    self?.onDone()
                }
            }
        }
        return keepAwake.union(busy)
    }

    // MARK: Browser scripting

    /// Chromium-style browsers whose AppleScript has `id of every tab of every window`.
    private static let tabBrowsers: Set<String> = [
        "company.thebrowser.dia", "company.thebrowser.browser", "com.google.chrome",
        "com.brave.browser", "com.microsoft.edgemac", "com.vivaldi.vivaldi",
    ]

    private static func supportsTabs(_ app: NSRunningApplication) -> Bool {
        tabBrowsers.contains(app.bundleIdentifier?.lowercased() ?? "")
    }

    private static func tabIDs(app: String, completion: @escaping @MainActor (Set<String>?) -> Void) {
        runOsascript("tell application \"\(app)\" to get id of every tab of every window") { output in
            completion(output.map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }) })
        }
    }

    private static func closeTabs(app: String, except keep: Set<String>, completion: @escaping @MainActor () -> Void) {
        tabIDs(app: app) { current in
            guard let current else { completion(); return }
            let extra = current.subtracting(keep)
            guard !extra.isEmpty else { completion(); return }
            let list = extra.map { "\"\($0)\"" }.joined(separator: ", ")
            // Per window: if every tab is the AI's, close the window. Otherwise
            // first focus one of the user's tabs (closing the active tab would
            // leave a blank one behind), then close the AI's tabs.
            let script = """
            tell application "\(app)"
              set extra to {\(list)}
              repeat with wid in (get id of every window)
                set w to (first window whose id is (wid as text))
                set tabIDs to {}
                repeat with t in (get id of every tab of w)
                  set end of tabIDs to (t as text)
                end repeat
                set keepIDs to {}
                repeat with t in tabIDs
                  if extra does not contain (t as text) then set end of keepIDs to (t as text)
                end repeat
                if (count of keepIDs) is 0 then
                  close w
                else
                  if extra contains ((id of active tab of w) as text) then focus (first tab of w whose id is (item 1 of keepIDs))
                  repeat with t in tabIDs
                    if extra contains (t as text) then close (first tab of w whose id is (t as text))
                  end repeat
                end if
              end repeat
            end tell
            """
            runOsascript(script) { _ in completion() }
        }
    }

    /// Runs osascript off the main thread with a 10 s timeout. nil on failure.
    private static func runOsascript(_ script: String, completion: @escaping @MainActor (String?) -> Void) {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            var result: String?
            if (try? p.run()) != nil {
                let deadline = Date().addingTimeInterval(10)
                while p.isRunning && Date() < deadline { usleep(50_000) }
                if p.isRunning { p.terminate() }
                else if p.terminationStatus == 0 {
                    result = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }
}
