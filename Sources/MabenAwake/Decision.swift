import Foundation

/// The decisions behind `Model.apply()`, as pure functions of plain values, so
/// they can be tested without touching processes, power settings or the lid
/// (`tests/MabenAwakeTests`). `Model` gathers the facts, calls these, and
/// carries out what they return.
enum Decision {
    // MARK: Away

    /// Who is at the Mac. `lidAway`: the lid is closed and no external display is
    /// on. `lockedAway`: the screen is locked and the user asked for that to count
    /// (Macs without a lid, or walking away from a laptop).
    struct Presence: Equatable {
        var lidAway: Bool
        var lockedAway: Bool
        /// Nobody is using the Mac: apps may be frozen and cleaned up after.
        var away: Bool { lidAway || lockedAway }
    }

    static func presence(lidClosed: Bool, externalDisplay: Bool, screenLocked: Bool, freezeWhileLocked: Bool) -> Presence {
        Presence(lidAway: lidClosed && !externalDisplay, lockedAway: screenLocked && freezeWhileLocked)
    }

    // MARK: Heat

    /// Overheated while away: stop keeping the Mac awake so it sleeps and cools
    /// down. Cleared only once someone is back (`heatApplies` false), not when
    /// it cools down, so a Mac in a bag doesn't heat up again.
    static func overheated(current: Bool, heatApplies: Bool, serious: Bool) -> Bool {
        if heatApplies && serious { return true }
        if !heatApplies { return false }
        return current
    }

    // MARK: Power

    struct PowerInput {
        /// Kept awake by hand (and, if asked, an Always on app is running).
        var manual: Bool
        var hasRequests: Bool
        var overheated: Bool
        var lidClosedMode: Bool
        var lidHelperInstalled: Bool
        var lowBattery: Bool
        var batteryCutoff: Int
        var lidAway: Bool
        var keepUnlockedWhenClosed: Bool
    }

    struct Power: Equatable {
        /// Hold the keep-awake power assertion.
        var keepAwake: Bool
        /// Block closed-lid sleep (`pmset disablesleep 1`).
        var blockLidSleep: Bool
        /// The event log line for closed-lid sleep.
        var lidLine: String
        /// Hold a display-sleep assertion so the screen doesn't lock.
        var keepScreenOn: Bool
    }

    static func power(_ i: PowerInput) -> Power {
        let keepAwake = (i.manual || i.hasRequests) && !i.overheated
        let blockLid = keepAwake && i.lidClosedMode && i.lidHelperInstalled && !i.lowBattery
        let lidLine = blockLid ? "closed-lid sleep: blocked"
            : "closed-lid sleep: allowed (" + (!keepAwake ? "not keeping awake"
                : !i.lidClosedMode ? "lid-closed mode is off"
                : !i.lidHelperInstalled ? "lid helper not installed"
                : "battery below \(i.batteryCutoff)%") + ")"
        // Never with the lid open: there the screen should sleep (and lock) as usual.
        let screenOn = keepAwake && i.lidAway && i.keepUnlockedWhenClosed
        return Power(keepAwake: keepAwake, blockLidSleep: blockLid, lidLine: lidLine, keepScreenOn: screenOn)
    }

    // MARK: Freezing

    /// What `Model` knows about one running app.
    struct App {
        var pid: pid_t
        var mode: AppMode
        /// An AI asked for it (`awake need`, or a hook did).
        var requested: Bool
        /// Running from outside the Applications folders: an AI's own build.
        var isDevBuild: Bool
        /// Still launching, or launched in the last 15 seconds.
        var starting: Bool
    }

    struct FreezeInput {
        /// Keeping the Mac awake, freezing is on, and nobody is at the Mac.
        var freezing: Bool
        /// An AI turn or `awake run` is in progress.
        var aiWorking: Bool
        /// Someone is at the Mac and touched it in the last minute.
        var userPresent: Bool
        var frontmost: pid_t?
        /// Apps the user brought to the front after they were frozen.
        var userResumed: Set<pid_t>
        /// Apps that must stay awake whatever their mode: an AI runs inside them,
        /// or they are closing the tabs an AI opened.
        var keepAwake: Set<pid_t>
    }

    /// Whether the app is needed right now, whatever the lid does.
    static func isNeeded(_ app: App, aiWorking: Bool) -> Bool {
        switch app.mode {
        case .always: true
        case .whileAI: aiWorking || app.requested
        // A dev build an AI just launched to test stays awake while an AI works,
        // then freezes like the rest.
        case .onDemand: app.requested || (aiWorking && app.isDevBuild)
        }
    }

    static func shouldFreeze(_ app: App, _ i: FreezeInput) -> Bool {
        guard i.freezing, !isNeeded(app, aiWorking: i.aiWorking) else { return false }
        let userIsUsingIt = i.userPresent && (app.pid == i.frontmost || i.userResumed.contains(app.pid))
        // Never freeze an app that is still starting up: frozen mid-launch it
        // finishes launching (and grabs focus) whenever it's next woken.
        return !userIsUsingIt && !app.starting && !i.keepAwake.contains(app.pid)
    }
}

// MARK: - Helper processes

/// Every process of this user, to find what belongs to an app. An app's helpers
/// are its child processes and the processes macOS holds it *responsible* for:
/// XPC services and helpers that launchd starts on its behalf (WebKit's page
/// processes, open and save panels, QuickLook…), which aren't its children.
struct ProcessTable {
    struct Entry: Equatable {
        var parent: pid_t
        /// The app macOS holds responsible for this process (itself if none).
        var responsible: pid_t
    }

    var entries: [pid_t: Entry]

    /// The processes that belong to `app`, apart from `app` itself and anything
    /// in `excluded` (other apps, which have a mode of their own, and the
    /// processes an AI runs in). A process an excluded one started is skipped
    /// with it.
    ///
    /// Responsibility is inherited: everything an agent running inside an
    /// editor starts counts as the editor's. So it only adds processes launchd
    /// started (XPC services); one with a real parent belongs where its parent does.
    func helpers(of app: pid_t, excluding excluded: Set<pid_t>) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        var roots: [pid_t] = []
        for (pid, entry) in entries {
            children[entry.parent, default: []].append(pid)
            if entry.responsible == app && pid != app && entry.parent <= 1 { roots.append(pid) }
        }
        var found = Set<pid_t>()
        var stack = (children[app] ?? []) + roots
        while let pid = stack.popLast() {
            guard pid > 1, pid != app, !excluded.contains(pid), found.insert(pid).inserted else { continue }
            stack += children[pid] ?? []
        }
        return found.sorted()
    }
}

// MARK: - Crash loop

/// Notices a version that crashes again and again right after starting, so it
/// can be swapped for the copy it replaced. Times are seconds since 1970.
enum CrashLoop {
    /// This many unclean starts…
    static let limit = 4
    /// …within this many seconds of each other is a crash loop.
    static let window: TimeInterval = 180

    /// Records a start. Returns the starts to keep, and whether this is a crash
    /// loop. `starts` are the earlier starts of this version that didn't end in
    /// a clean quit and didn't last long enough to count as stable.
    static func record(start now: TimeInterval, after starts: [TimeInterval]) -> (starts: [TimeInterval], looping: Bool) {
        let recent = starts.filter { now - $0 < window && $0 <= now } + [now]
        return (recent, recent.count >= limit)
    }
}

// MARK: - While you were away

/// What happened while nobody was at the Mac, for the menu and the event log.
struct AwaySummary: Equatable {
    var duration: TimeInterval
    var keptAwake: TimeInterval
    /// Agents that worked (Claude Code, Codex…), and other requests (`awake run`).
    var agents: [String]
    var otherRequests: Bool
    var mostFrozen: Int
    var batteryStart: Int?
    var batteryEnd: Int?
    /// Why it stopped keeping the Mac awake early, if it did.
    var stoppedBecause: String?

    /// One line: "Away 2 h 5 m · kept awake 1 h 40 m · Claude Code worked · battery 86% → 61%".
    var text: String {
        var parts = ["Away \(Self.format(duration))"]
        if keptAwake >= 60 { parts.append("kept awake \(Self.format(keptAwake))") }
        if !agents.isEmpty {
            parts.append(Self.list(agents) + " worked")
        } else if otherRequests {
            parts.append("a script ran")
        }
        if mostFrozen > 0 { parts.append(mostFrozen == 1 ? "1 app frozen" : "\(mostFrozen) apps frozen") }
        if let a = batteryStart, let b = batteryEnd, a != b { parts.append("battery \(a)% → \(b)%") }
        return parts.joined(separator: " · ")
    }

    static func format(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 1 { return "<1 m" }
        return m >= 60 ? "\(m / 60) h \(m % 60) m" : "\(m) m"
    }

    private static func list(_ names: [String]) -> String {
        names.count <= 2 ? names.joined(separator: " and ") : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}

/// Collects an `AwaySummary` from the 3-second checks while away.
struct AwayTracker {
    let start: Date
    let batteryStart: Int?
    private var last: Date
    private var keptAwake: TimeInterval = 0
    private var agents: [String] = []
    private var otherRequests = false
    private var mostFrozen = 0
    private var stoppedBecause: String?

    init(start: Date, battery: Int?) {
        self.start = start
        batteryStart = battery
        last = start
    }

    /// One check. A gap longer than 30 seconds means the Mac slept in between,
    /// which doesn't count as kept awake.
    mutating func record(at now: Date, keepingAwake: Bool, agents working: [String], otherRequests other: Bool,
                         frozen: Int, stoppedBecause stop: String?) {
        let dt = now.timeIntervalSince(last)
        if keepingAwake && dt > 0 && dt < 30 { keptAwake += dt }
        last = now
        for agent in working where !agents.contains(agent) { agents.append(agent) }
        otherRequests = otherRequests || other
        mostFrozen = max(mostFrozen, frozen)
        if let stop, stoppedBecause == nil { stoppedBecause = stop }
    }

    /// The summary, or nil when there's nothing worth showing: a short absence,
    /// or one in which the Mac wasn't kept awake.
    func finish(at now: Date, battery: Int?) -> AwaySummary? {
        let duration = now.timeIntervalSince(start)
        guard duration >= 120, keptAwake >= 60 || stoppedBecause != nil else { return nil }
        return AwaySummary(duration: duration, keptAwake: keptAwake, agents: agents, otherRequests: otherRequests,
                           mostFrozen: mostFrozen, batteryStart: batteryStart, batteryEnd: battery,
                           stoppedBecause: stoppedBecause)
    }
}
