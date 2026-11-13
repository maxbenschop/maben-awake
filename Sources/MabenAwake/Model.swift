import AppKit
import Combine
import IOKit.pwr_mgt
import ServiceManagement

/// How Maben Awake treats an app while it's keeping the Mac awake.
enum AppMode: String, CaseIterable, Identifiable {
    case always, whileAI, onDemand
    var id: String { rawValue }
    var label: String {
        switch self {
        case .always: "Always on"
        case .whileAI: "While AI works"
        case .onDemand: "When AI asks"
        }
    }
    /// Short form for the compact mode button in the menu.
    var shortLabel: String {
        switch self {
        case .always: "Always on"
        case .whileAI: "With AI"
        case .onDemand: "On request"
        }
    }
    var symbol: String {
        switch self {
        case .always: "sun.max.fill"
        case .whileAI: "sparkles"
        case .onDemand: "moon.zzz.fill"
        }
    }
    var explanation: String {
        switch self {
        case .always: "Never frozen."
        case .whileAI: "Awake while any AI turn or `awake run` is active."
        case .onDemand: "Frozen until an AI uses it; woken by itself when a command needs it."
        }
    }
}

/// What the menu bar icon and the menu header show.
enum KeepAwakeState: Equatable {
    case idle, awake, aiWorking, overheated
}

/// One row in the app list.
struct AppEntry: Identifiable, Hashable {
    let id: pid_t
    let bundleID: String
    let name: String
    let icon: NSImage?
    let isPaused: Bool
}

@MainActor
final class Model: ObservableObject {
    static let shared = Model()

    // MARK: Settings (persisted)

    /// Keep the Mac awake. Display may still turn off.
    @Published var keepAwake: Bool {
        didSet { defaults.set(keepAwake, forKey: "keepAwake"); apply() }
    }
    /// Only keep awake while at least one checked app is running.
    @Published var onlyWhileCheckedRunning: Bool {
        didSet { defaults.set(onlyWhileCheckedRunning, forKey: "onlyWhileCheckedRunning"); apply() }
    }
    /// Freeze apps that aren't needed right now (SIGSTOP) while keeping awake.
    @Published var pauseOthers: Bool {
        didSet {
            defaults.set(pauseOthers, forKey: "pauseOthers")
            if !pauseOthers { userResumed.removeAll() }
            apply()
        }
    }
    /// Turn the screen brightness to 0 while the lid is closed, restore on open.
    @Published var dimWhenClosed: Bool {
        didSet { defaults.set(dimWhenClosed, forKey: "dimWhenClosed"); apply() }
    }
    /// Keep the display from idle-sleeping while the lid is closed, so macOS
    /// never shows the lock screen and an AI can still click in apps.
    @Published var keepUnlockedWhenClosed: Bool {
        didSet { defaults.set(keepUnlockedWhenClosed, forKey: "keepUnlockedWhenClosed"); apply() }
    }
    /// Lock the screen when the lid opens after it was kept unlocked, so whoever
    /// opens the lid has to log in, as without Maben Awake.
    @Published var lockWhenLidOpens: Bool {
        didSet { defaults.set(lockWhenLidOpens, forKey: "lockWhenLidOpens") }
    }
    /// A locked screen counts as away too: apps are frozen while it's locked.
    /// On by default on Macs without a lid, where the lid never closes.
    @Published var freezeWhileLocked: Bool {
        didSet { defaults.set(freezeWhileLocked, forKey: "freezeWhileLocked"); apply() }
    }
    /// Also stay awake with the lid closed (needs the one-time helper).
    @Published var lidClosedMode: Bool {
        didSet { defaults.set(lidClosedMode, forKey: "lidClosedMode"); apply() }
    }
    /// On battery below this percentage, closed-lid sleep is allowed again.
    @Published var batteryCutoff: Int {
        didSet { defaults.set(batteryCutoff, forKey: "batteryCutoff"); apply() }
    }
    /// Bundle IDs of apps that must stay alive.
    @Published private(set) var checked: Set<String> {
        didSet { defaults.set(Array(checked), forKey: "checked") }
    }
    /// Protected-by-default apps the user explicitly set to "When AI asks".
    @Published private(set) var explicitOnDemand: Set<String> {
        didSet { defaults.set(Array(explicitOnDemand), forKey: "explicitOnDemand") }
    }
    /// Bundle IDs of apps that only run while an AI is working.
    @Published private(set) var aiOnly: Set<String> {
        didSet { defaults.set(Array(aiOnly), forKey: "aiOnly") }
    }

    // MARK: Live state

    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var leases: [Lease] = []
    @Published private(set) var isAsserting = false
    @Published private(set) var lidHelperInstalled = LidControl.isHelperInstalled
    @Published private(set) var lidSleepDisabled = false
    @Published private(set) var lidClosed = LidControl.isLidClosed
    /// The root lid-open failsafe is installed and current (see Failsafe.swift).
    @Published private(set) var failsafeInstalled = false
    @Published private(set) var installingFailsafe = false
    /// Start at login and restart automatically after a crash.
    @Published var launchAtLogin: Bool = false {
        didSet {
            guard !isPreview else { return }
            defaults.set(launchAtLogin, forKey: "wantAgent")
            guard launchAtLogin != (Instance.isEnabled) else { return }
            let actual = Instance.setEnabled(launchAtLogin)
            if actual != launchAtLogin { launchAtLogin = actual }
        }
    }
    /// Nobody is at the Mac: the lid is closed with no external display, or the
    /// screen is locked and `freezeWhileLocked` is on.
    @Published private(set) var away = false
    /// What happened the last time nobody was at the Mac, until dismissed.
    @Published private(set) var awaySummary: AwaySummary?
    /// Mac got too hot while away; we stopped keeping it awake so it can sleep.
    @Published private(set) var overheated = false
    /// Set when this run started after the previous one crashed.
    @Published private(set) var recoveredFromCrash = false

    private let defaults: UserDefaults
    /// Preview models (UI snapshots) never touch processes, power or launchd.
    private let isPreview: Bool
    private var assertionID: IOPMAssertionID = 0
    /// Display-sleep assertion, held only while away (see `keepUnlockedWhenClosed`).
    private var displayAssertionID: IOPMAssertionID = 0
    private var pausedPIDs = Set<pid_t>()
    /// Helper processes (browser tabs, Electron helpers, XPC services…) frozen with each app.
    private var pausedChildren: [pid_t: [pid_t]] = [:]
    /// The running apps from the last scan. Listing them asks Launch Services
    /// about every app, so with the lid open and no window showing (when nothing
    /// can be frozen and nobody sees the list) it's done every 30 seconds instead
    /// of every 3, and right away when an app starts or quits.
    private var appCache: [NSRunningApplication]?
    private var appsScannedAt = Date.distantPast
    /// App icons by pid: loading one reads the app's bundle from disk.
    private var iconCache: [pid_t: NSImage] = [:]
    private var watchers: Watchers?
    private var lastLidAway: Bool?
    /// The screen was kept on (and unlocked) during this lid-closed stretch.
    private var screenHeldWhileAway = false
    private var awayTracker: AwayTracker?
    private var loggedLock: String?
    /// When each app last stopped being frontmost, so apps the user clicked
    /// can be frozen again once they've been in the background a while.
    private var leftFrontAt: [pid_t: Date] = [:]
    private var lastFrontmost: pid_t?
    private var leaseWatcher: DispatchSourceFileSystemObject?
    private var termSource: DispatchSourceSignal?
    private var lastAway: Bool?
    private lazy var cleanup = AICleanup { [weak self] in self?.apply() }
    /// Apps the user brought to front after we paused them; leave these alone
    /// until pausing is toggled off and on again.
    private var userResumed = Set<pid_t>()
    /// Last value we sent to `pmset disablesleep`; nil = unknown, forces a reset.
    private var appliedLidSleepDisabled: Bool?
    /// Last decisions written to the event log, so only changes get logged.
    private var loggedAwake: String?
    private var loggedLid: String?
    private var loggedScreen: String?
    private var loggedLidState: String?
    private var loggedPower: String?
    /// Set after a failed `pmset` call so a broken helper doesn't flood the log.
    private var lidSetFailed = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let startedAt = Date()

    init() {
        defaults = .standard
        isPreview = false
        keepAwake = defaults.bool(forKey: "keepAwake")
        onlyWhileCheckedRunning = defaults.bool(forKey: "onlyWhileCheckedRunning")
        // On by default: it only ever applies with the lid closed, which needs the
        // one-time lid setup (and that installs the lid-open failsafe with it).
        pauseOthers = defaults.object(forKey: "pauseOthers") as? Bool ?? true
        lidClosedMode = defaults.object(forKey: "lidClosedMode") as? Bool ?? true
        dimWhenClosed = defaults.object(forKey: "dimWhenClosed") as? Bool ?? true
        keepUnlockedWhenClosed = defaults.object(forKey: "keepUnlockedWhenClosed") as? Bool ?? true
        lockWhenLidOpens = defaults.object(forKey: "lockWhenLidOpens") as? Bool ?? true
        freezeWhileLocked = defaults.object(forKey: "freezeWhileLocked") as? Bool ?? !LidControl.hasLid
        batteryCutoff = defaults.object(forKey: "batteryCutoff") as? Int ?? 20
        checked = Set(defaults.stringArray(forKey: "checked") ?? [])
        aiOnly = Set(defaults.stringArray(forKey: "aiOnly") ?? [])
        explicitOnDemand = Set(defaults.stringArray(forKey: "explicitOnDemand") ?? [])

        // Crash detection: "running" is cleared by a clean shutdown.
        if defaults.bool(forKey: "running") {
            recoveredFromCrash = true
            EventLog.write("started after a crash: thawing frozen apps, restoring power settings")
        } else {
            EventLog.write("started")
        }
        defaults.set(true, forKey: "running")

        // Start at login + crash restarts (launchd agent): on by default when
        // installed in /Applications, and re-registered after every update.
        let wantAgent = defaults.object(forKey: "wantAgent") as? Bool
            ?? Bundle.main.bundlePath.hasPrefix("/Applications/")
        if wantAgent && !Instance.isEnabled { _ = Instance.setEnabled(true) }
        launchAtLogin = Instance.isEnabled
        failsafeInstalled = Failsafe.isUpToDate

        // If we quit or crashed while the screen was dimmed, bring it back.
        if let saved = defaults.object(forKey: "savedBrightness") as? Float, !LidControl.isLidClosed {
            Brightness.set(saved)
            defaults.removeObject(forKey: "savedBrightness")
        }

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.userActivated(app) }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                self?.pausedPIDs.remove(app.processIdentifier)
                self?.pausedChildren[app.processIdentifier] = nil
                self?.userResumed.remove(app.processIdentifier)
                self?.appCache = nil
                self?.apply()
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.appCache = nil; self?.apply() } })
        // The menu or Settings opening: show the current apps straight away.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.appCache = nil; self?.apply() } })

        // Log every sleep and wake with the state at that moment, so a Mac
        // that fell asleep unexpectedly can be explained afterwards.
        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.logSnapshot("Mac is going to sleep") } })
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.logSnapshot("Mac woke up")
                self?.apply()
            }
        })

        // A previous instance may have died (crash, SIGTERM from an installer)
        // while apps were frozen: thaw anything still stopped.
        thawStrays()

        // `kill`/`pkill` sends SIGTERM, which skips applicationWillTerminate.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { MainActor.assumeIsolated { Model.shared.shutdown() }; exit(0) }
        term.resume()
        termSource = term

        // React to AI requests instantly instead of waiting for the next poll.
        let fd = open(LeaseStore.directory.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.apply() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            leaseWatcher = source
        }

        // React to the lid and the screen lock at once, not on the next check.
        watchers = Watchers { [weak self] in self?.apply() }

        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.apply() }
        }
        apply()

        // Still running after a minute: this version starts fine.
        DispatchQueue.main.asyncAfter(deadline: .now() + CrashGuard.stableAfter) { CrashGuard.markStable() }
    }

    /// A model with canned state for rendering the UI; has no side effects.
    init(preview apps: [AppEntry], leases: [Lease], asserting: Bool, away: Bool = false,
         modes: [String: AppMode] = [:], lidHelper: Bool = true, recovered: Bool = false, overheated: Bool = false,
         awaySummary: AwaySummary? = nil) {
        defaults = UserDefaults(suiteName: "gg.maben.awake.preview")!
        isPreview = true
        keepAwake = true
        onlyWhileCheckedRunning = false
        pauseOthers = true
        dimWhenClosed = true
        keepUnlockedWhenClosed = true
        lockWhenLidOpens = true
        freezeWhileLocked = false
        self.awaySummary = awaySummary
        lidClosedMode = true
        batteryCutoff = 20
        checked = Set(modes.filter { $0.value == .always }.keys)
        aiOnly = Set(modes.filter { $0.value == .whileAI }.keys)
        explicitOnDemand = Set(modes.filter { $0.value == .onDemand }.keys)
        self.apps = apps
        self.leases = leases
        isAsserting = asserting
        self.away = away
        lidClosed = away
        lidSleepDisabled = asserting && lidHelper
        lidHelperInstalled = lidHelper
        recoveredFromCrash = recovered
        self.overheated = overheated
        launchAtLogin = true
    }

    // MARK: Public actions

    func mode(of bundleID: String) -> AppMode {
        if checked.contains(bundleID) { return .always }
        if aiOnly.contains(bundleID) { return .whileAI }
        if explicitOnDemand.contains(bundleID) { return .onDemand }
        return Policy.isProtectedByDefault(bundleID) ? .always : .onDemand
    }

    func isProtectedByDefault(_ bundleID: String) -> Bool { Policy.isProtectedByDefault(bundleID) }

    func setMode(_ entry: AppEntry, _ mode: AppMode) {
        checked.remove(entry.bundleID)
        aiOnly.remove(entry.bundleID)
        explicitOnDemand.remove(entry.bundleID)
        switch mode {
        case .always: checked.insert(entry.bundleID)
        case .whileAI: aiOnly.insert(entry.bundleID)
        case .onDemand:
            if Policy.isProtectedByDefault(entry.bundleID) { explicitOnDemand.insert(entry.bundleID) }
        }
        userResumed.remove(entry.id)
        apply()
    }

    /// Bundle IDs with a mode the user picked, whether or not they're running.
    var customizedBundleIDs: Set<String> { checked.union(aiOnly).union(explicitOnDemand) }

    /// Back to the default mode (Always on for protected apps, else When AI asks).
    func resetMode(_ bundleID: String) {
        checked.remove(bundleID)
        aiOnly.remove(bundleID)
        explicitOnDemand.remove(bundleID)
        apply()
    }

    func resetAllModes() {
        checked.removeAll()
        aiOnly.removeAll()
        explicitOnDemand.removeAll()
        apply()
    }

    func setMode(bundleID: String, _ mode: AppMode) {
        if let entry = apps.first(where: { $0.bundleID == bundleID }) { return setMode(entry, mode) }
        resetMode(bundleID)
        switch mode {
        case .always: checked.insert(bundleID)
        case .whileAI: aiOnly.insert(bundleID)
        case .onDemand: if Policy.isProtectedByDefault(bundleID) { explicitOnDemand.insert(bundleID) }
        }
        apply()
    }

    var frozenCount: Int { apps.filter(\.isPaused).count }

    func dismissCrashNotice() { recoveredFromCrash = false }
    func dismissAwaySummary() { awaySummary = nil }

    var state: KeepAwakeState {
        if overheated { return .overheated }
        if !isAsserting { return .idle }
        return aiWorking ? .aiWorking : .awake
    }

    /// An AI is actively working (a turn or `awake run`), as opposed to only
    /// waiting on a scheduled wake-up or cron.
    var aiWorking: Bool { leases.contains(where: \.isWork) }

    /// Whether some AI asked for this app via `awake need` (or a hook did for it).
    private func isRequested(_ app: NSRunningApplication) -> Bool {
        leases.contains { $0.app.map { Self.matches(app, $0) } ?? false }
    }

    /// Whether `app` is what a lease's app string ("Dia", "browser", a bundle ID…) means.
    private static func matches(_ app: NSRunningApplication, _ wantRaw: String) -> Bool {
        let want = wantRaw.lowercased()
        let bundle = app.bundleIdentifier?.lowercased() ?? ""
        let name = app.localizedName?.lowercased() ?? ""
        if want == "browser" { return bundle == defaultBrowser }
        return want == bundle || want == name || name.hasPrefix(want) || bundle.hasSuffix("." + want)
    }

    private static let defaultBrowser: String = {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
              let id = Bundle(url: url)?.bundleIdentifier else { return "" }
        return id.lowercased()
    }()

    func installLidHelper() {
        guard !isPreview else { return }
        lidHelperInstalled = LidControl.installHelper()
        failsafeInstalled = Failsafe.isUpToDate
        appliedLidSleepDisabled = nil
        apply()
    }

    /// Installs or updates the lid-open failsafe (asks for the admin password).
    func installFailsafe() {
        guard !isPreview, !installingFailsafe else { return }
        installingFailsafe = true
        defaults.set(Failsafe.bundledVersion, forKey: "failsafeOfferedVersion")
        Failsafe.install { ok in
            Task { @MainActor in
                let model = Model.shared
                model.installingFailsafe = false
                model.failsafeInstalled = Failsafe.isUpToDate
                EventLog.write(ok ? "lid-open failsafe installed" : "lid-open failsafe not installed (cancelled or failed)")
            }
        }
    }

    func release(_ lease: Lease) {
        guard !isPreview else { return }
        LeaseStore.remove(lease); apply()
    }
    func releaseAllLeases() {
        guard !isPreview else { return }
        LeaseStore.removeAll(); apply()
    }

    /// One-line headline for the menu header.
    var headline: String {
        switch state {
        case .overheated: "Cooling down"
        case .idle: "Mac can sleep"
        case .awake: "Keeping Mac awake"
        case .aiWorking: "AI is working"
        }
    }

    /// Why the Mac is (or isn't) being kept awake.
    var statusText: String {
        if overheated { return "Too hot with the lid closed, so sleep is allowed" }
        if !isAsserting {
            if keepAwake && onlyWhileCheckedRunning { return "Waiting for an \"Always on\" app to run" }
            return keepAwake ? "Sleeps normally" : "Sleeps normally · no AI requests"
        }
        var parts: [String] = []
        let requests = leases.count
        if requests > 0 { parts.append(requests == 1 ? "1 AI request" : "\(requests) AI requests") }
        else { parts.append("Kept awake manually") }
        let place = lidClosed ? "lid closed" : "screen locked"
        if away { parts.append(pauseOthers ? "\(place), \(frozenCount) frozen" : place) }
        else if lidClosed { parts.append("external display") }
        else if lidSleepDisabled { parts.append("lid can close") }
        return parts.joined(separator: " · ")
    }

    /// Resume everything we paused. Called before quitting.
    func shutdown() {
        guard !isPreview else { return }
        for pid in pausedPIDs { resume(pid: pid) }
        FrozenList.write([])
        releaseAssertion()
        releaseDisplayAssertion()
        LidControl.setSleepDisabled(false)
        restoreBrightness()
        Heartbeat.write(lidClosed: LidControl.isLidClosed, savedBrightness: nil, quit: true)
        defaults.set(false, forKey: "running")
        CrashGuard.cleanExit()
        EventLog.write("quit cleanly")
    }

    private func dimScreen() {
        guard defaults.object(forKey: "savedBrightness") == nil, let current = Brightness.get() else { return }
        defaults.set(current, forKey: "savedBrightness")
        Brightness.set(0)
    }

    private func restoreBrightness() {
        guard let saved = defaults.object(forKey: "savedBrightness") as? Float else { return }
        Brightness.set(saved)
        defaults.removeObject(forKey: "savedBrightness")
    }

    // MARK: Core logic

    /// The regular (Dock) apps, from the cache unless `fresh` or it's 30 s old.
    private func runningApps(fresh: Bool) -> [NSRunningApplication] {
        if !fresh, let appCache, Date().timeIntervalSince(appsScannedAt) < 30 { return appCache }
        let me = ProcessInfo.processInfo.processIdentifier
        let list = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                // -1 means the app has no process (e.g. it is quitting).
                && Signals.isSafeTarget($0.processIdentifier)
                && $0.processIdentifier != me
                && $0.bundleIdentifier != "com.apple.finder"
                && $0.bundleIdentifier != nil
        }
        appCache = list
        appsScannedAt = Date()
        let pids = Set(list.map(\.processIdentifier))
        iconCache = iconCache.filter { pids.contains($0.key) }
        return list
    }

    private func apply() {
        guard !isPreview else { return }
        let currentLeases = LeaseStore.active()
        if currentLeases != leases { leases = currentLeases }

        // Away = lid closed and no external display (clamshell mode means the
        // user is working on the external screen, so nothing is frozen or dimmed),
        // or a locked screen when the user asked for that to count.
        let closed = LidControl.isLidClosed
        let locked = LidControl.isScreenLocked
        let presence = Decision.presence(lidClosed: closed, externalDisplay: closed && LidControl.externalDisplayActive,
                                         screenLocked: locked, freezeWhileLocked: freezeWhileLocked)
        let nowAway = presence.away
        if closed != lidClosed { lidClosed = closed }
        if nowAway != away { away = nowAway }
        logChange(&loggedLidState, closed ? (presence.lidAway ? "lid closed" : "lid closed, external display") : "lid open")
        if freezeWhileLocked { logChange(&loggedLock, locked ? "screen locked: counts as away" : "screen unlocked") }

        // With the lid open and no window showing, nothing can be frozen and
        // nobody sees the list, so the apps can come from the cache.
        let running = runningApps(fresh: nowAway || closed || !pausedPIDs.isEmpty || UIVisibility.anyWindowVisible)

        // 1. Should we be holding the Mac awake right now?
        //    Either the manual toggle says so, or an external tool holds a lease.
        // Only apps the user explicitly set to "Always on" count here, not the
        // protected defaults (an open Mail shouldn't keep the Mac awake).
        let anyCheckedRunning = running.contains { checked.contains($0.bundleIdentifier!) }
        let manual = keepAwake && (!onlyWhileCheckedRunning || anyCheckedRunning)
        let power = LidControl.powerDescription
        logChange(&loggedPower, power == "AC" ? "power: AC" : "power: battery",
                  detail: power == "AC" ? nil : String(power.dropFirst("battery ".count)))

        // Heat check: a closed laptop (e.g. in a bag) that gets seriously hot is
        // allowed to sleep. Cleared once someone is back at the Mac.
        let thermal = (defaults.object(forKey: "testThermalState") as? Int)
            .flatMap(ProcessInfo.ThermalState.init(rawValue:)) ?? ProcessInfo.processInfo.thermalState
        let heatApplies = presence.lidAway || defaults.object(forKey: "testThermalState") != nil
        let hot = Decision.overheated(current: overheated, heatApplies: heatApplies,
                                      serious: thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue)
        if hot != overheated {
            overheated = hot
            EventLog.write(hot ? "thermal state \(thermal.rawValue) while lid closed: releasing keep-awake so the Mac can sleep"
                               : "back at the Mac: heat cutoff cleared")
        }

        let lowBattery = LidControl.batteryBelow(batteryCutoff)
        let decision = Decision.power(.init(
            manual: manual, hasRequests: !currentLeases.isEmpty, overheated: overheated,
            lidClosedMode: lidClosedMode, lidHelperInstalled: lidHelperInstalled, lowBattery: lowBattery,
            batteryCutoff: batteryCutoff, lidAway: presence.lidAway, keepUnlockedWhenClosed: keepUnlockedWhenClosed))
        decision.keepAwake ? acquireAssertion() : releaseAssertion()
        logChange(&loggedAwake, awakeDecision(running: running, manual: manual, leases: currentLeases))

        // 2. Closed-lid sleep: only blocked while we're keeping the Mac awake,
        //    and never on a nearly empty battery.
        let wantLid = decision.blockLidSleep
        logChange(&loggedLid, decision.lidLine)
        // Compare against the real system value, not just what we last set:
        // another app can turn `disablesleep` off, and then closing the lid
        // would sleep the Mac even though we're holding it awake.
        let actual = LidControl.isSleepDisabled
        if wantLid && !actual {
            if appliedLidSleepDisabled == true {
                EventLog.write("closed-lid sleep was re-enabled by another app or pmset; blocking it again")
            }
            if LidControl.setSleepDisabled(true) {
                appliedLidSleepDisabled = true
                lidSetFailed = false
            } else if !lidSetFailed {
                lidSetFailed = true
                EventLog.write("ERROR: could not run 'sudo -n pmset disablesleep 1'; the Mac will sleep when the lid closes")
            }
        } else if !wantLid && appliedLidSleepDisabled != false {
            // Only undo what we set ourselves; leave other apps' settings alone.
            if appliedLidSleepDisabled == true || actual { LidControl.setSleepDisabled(false) }
            appliedLidSleepDisabled = false
        }
        let blocked = wantLid && LidControl.isSleepDisabled
        if blocked != lidSleepDisabled { lidSleepDisabled = blocked }

        // 3. Screen lock: with the lid closed the built-in display stays on
        //    (dimmed to 0 below) until the display-sleep timer fires, and a few
        //    minutes later macOS locks the screen. From then on an AI can't
        //    click anything, so hold a display-sleep assertion while away.
        //    Never with the lid open: there the screen should sleep as usual.
        decision.keepScreenOn ? acquireDisplayAssertion() : releaseDisplayAssertion()
        if presence.lidAway {
            if decision.keepScreenOn { screenHeldWhileAway = true }
            logChange(&loggedScreen, decision.keepScreenOn ? "screen: kept on so it doesn't lock"
                : "screen: may turn off and lock (" + (!decision.keepAwake ? "not keeping awake" : "keep-unlocked is off") + ")")
        } else {
            loggedScreen = nil
        }

        // 4. Lid transitions: dim the screen while the lid is closed, restore it
        //    when it opens, and lock it if it was kept unlocked meanwhile.
        if presence.lidAway != lastLidAway {
            let wasLidAway = lastLidAway == true
            lastLidAway = presence.lidAway
            if presence.lidAway {
                if dimWhenClosed { dimScreen() }
            } else {
                restoreBrightness()
                if wasLidAway && !closed && screenHeldWhileAway && lockWhenLidOpens {
                    EventLog.write(LidControl.lockScreen() ? "lid opened: locked the screen, which was kept unlocked"
                                                           : "lid opened: could not lock the screen")
                }
                screenHeldWhileAway = false
            }
        }
        // Back at the Mac (lid open, or screen unlocked): wake anything a
        // previous instance left frozen, and sum up what happened meanwhile.
        if nowAway != lastAway {
            lastAway = nowAway
            if nowAway {
                awayTracker = AwayTracker(start: Date(), battery: LidControl.batteryPercent)
            } else {
                thawStrays()
                finishAwaySummary()
            }
        }
        // Tell the failsafe daemon what we've done (only written on change).
        Heartbeat.write(lidClosed: closed, savedBrightness: defaults.object(forKey: "savedBrightness") as? Float)
        offerFailsafeIfNeeded(away: nowAway || locked)

        // 5. Pause / resume the other apps. Only while away: otherwise the user
        //    may click any app at any moment.
        let freezing = decision.keepAwake && pauseOthers && nowAway
        // Apps an AI is running inside (terminal, editor, T3…) are never frozen.
        let owners = currentLeases.map(\.owner).filter { $0 > 0 }
        let aiHosts = Self.ancestors(of: owners)
        let working = aiWorking

        // Quit apps the AI launched / close tabs it opened, once it's done.
        let requestedApps = Set(currentLeases.compactMap(\.app).map { $0.lowercased() })
        // `testCleanupWithLidOpen` lets tests exercise cleanup without closing the lid.
        let cleanupAway = nowAway || defaults.bool(forKey: "testCleanupWithLidOpen")
        let cleaningUp = cleanup.update(requested: requestedApps, lidClosed: cleanupAway) { want in
            running.first { Self.matches($0, want) }
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // The frontmost app is only protected while someone is actually at the
        // Mac. With the lid closed or no input for a minute, an app that grabbed
        // focus on its own (e.g. finishing its launch after an AI woke it) must
        // not stay awake forever.
        let userPresent = !nowAway && LidControl.secondsSinceUserInput() < 60
        if !userPresent { userResumed.removeAll() }
        if frontmost != lastFrontmost {
            if let previous = lastFrontmost { leftFrontAt[previous] = Date() }
            lastFrontmost = frontmost
        }
        if !freezing {
            for pid in pausedPIDs { resume(pid: pid) }
        } else {
            let input = Decision.FreezeInput(freezing: true, aiWorking: working, userPresent: userPresent,
                                             frontmost: frontmost, userResumed: userResumed,
                                             keepAwake: cleaningUp.union(aiHosts))
            // Other apps have their own mode, and an AI's processes are never frozen with an app.
            let notHelpers = Set(running.map(\.processIdentifier)).union(aiHosts).union(owners)
            var table: ProcessTable?
            for app in running {
                let pid = app.processIdentifier
                // Apps the user clicked are left alone until they've been in the
                // background for a minute.
                if userResumed.contains(pid), pid != frontmost,
                   let left = leftFrontAt[pid], left.timeIntervalSinceNow < -60 {
                    userResumed.remove(pid)
                }
                let mode = mode(of: app.bundleIdentifier!)
                let facts = Decision.App(
                    pid: pid, mode: mode, requested: isRequested(app),
                    isDevBuild: mode == .onDemand && working && Policy.isDevBuild(app.bundleURL),
                    starting: !app.isFinishedLaunching || (app.launchDate.map { $0.timeIntervalSinceNow > -15 } ?? false))
                if Decision.shouldFreeze(facts, input) {
                    pause(pid: pid) {
                        if table == nil { table = ProcessTable.current() }
                        return table!.helpers(of: pid, excluding: notHelpers)
                    }
                } else {
                    resume(pid: pid)
                }
            }
        }
        FrozenList.write(running.filter { pausedPIDs.contains($0.processIdentifier) })

        if nowAway, awayTracker != nil {
            let agents = currentLeases.filter(\.isWork).compactMap { Integration.agentName(ofLease: $0.name) }
            let stop: String? = overheated ? "it got too hot"
                : (manual || !currentLeases.isEmpty) && presence.lidAway && lidClosedMode && lidHelperInstalled && lowBattery
                    ? "the battery fell below \(batteryCutoff)%" : nil
            awayTracker?.record(at: Date(), keepingAwake: decision.keepAwake, agents: agents,
                                otherRequests: currentLeases.contains { $0.isWork && Integration.agentName(ofLease: $0.name) == nil },
                                frozen: pausedPIDs.count, stoppedBecause: stop)
        }

        // 6. Refresh the list for the UI.
        var entries: [AppEntry] = []
        for app in running {
            let pid = app.processIdentifier
            let icon = iconCache[pid] ?? app.icon
            if iconCache[pid] == nil, let icon { iconCache[pid] = icon }
            entries.append(AppEntry(id: pid, bundleID: app.bundleIdentifier!, name: app.localizedName ?? app.bundleIdentifier!,
                                    icon: icon, isPaused: pausedPIDs.contains(pid)))
        }
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if entries != apps { apps = entries }
    }

    private func finishAwaySummary() {
        defer { awayTracker = nil }
        guard let summary = awayTracker?.finish(at: Date(), battery: LidControl.batteryPercent) else { return }
        awaySummary = summary
        EventLog.write("back at the Mac: \(summary.text)" + (summary.stoppedBecause.map { "; stopped early: \($0)" } ?? ""))
    }

    /// One line describing whether (and why) we're keeping the Mac awake.
    private func awakeDecision(running: [NSRunningApplication], manual: Bool, leases: [Lease]) -> String {
        if overheated { return "not keeping awake: too hot with the lid closed" }
        var reasons: [String] = []
        if manual {
            let names = running.filter { checked.contains($0.bundleIdentifier!) }.compactMap(\.localizedName)
            reasons.append(onlyWhileCheckedRunning ? "Always on: \(names.joined(separator: ", "))" : "kept awake manually")
        }
        if !leases.isEmpty { reasons.append("AI requests: \(leases.map(\.name).sorted().joined(separator: ", "))") }
        if !reasons.isEmpty { return "keeping awake (\(reasons.joined(separator: "; ")))" }
        if !keepAwake { return "not keeping awake: switched off, no AI requests" }
        return "not keeping awake: no Always on app running, no AI requests"
    }

    /// Writes `line` to the event log when it differs from the last one logged
    /// under `key`. `detail` is appended but doesn't count as a change.
    private func logChange(_ key: inout String?, _ line: String, detail: String? = nil) {
        guard line != key else { return }
        key = line
        EventLog.write(detail.map { "\(line) (\($0))" } ?? line)
    }

    /// Snapshot of everything that decides whether the Mac may sleep.
    func logSnapshot(_ event: String) {
        guard !isPreview else { return }
        EventLog.write("\(event): keeping awake=\(isAsserting), closed-lid sleep blocked=\(LidControl.isSleepDisabled), "
            + "lid \(LidControl.isLidClosed ? "closed" : "open"), \(LidControl.powerDescription), "
            + "\(leases.count) AI requests, \(pausedPIDs.count) apps frozen")
    }

    private func userActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pausedPIDs.contains(pid) else { return }
        resume(pid: pid)
        userResumed.insert(pid)
        apply()
    }

    /// Freezes an app, then its helpers (looked up only once the app is
    /// stopped, so it can't start new ones in between).
    private func pause(pid: pid_t, helpers: () -> [pid_t]) {
        guard Signals.isSafeTarget(pid), !pausedPIDs.contains(pid) else { return }
        guard Signals.send(SIGSTOP, to: pid) else { return }
        pausedPIDs.insert(pid)
        let children = helpers()
        for child in children { Signals.send(SIGSTOP, to: child) }
        pausedChildren[pid] = children
    }

    private func resume(pid: pid_t) {
        guard pausedPIDs.contains(pid) else { return }
        for child in pausedChildren[pid] ?? [] { Signals.send(SIGCONT, to: child) }
        Signals.send(SIGCONT, to: pid)
        pausedPIDs.remove(pid)
        pausedChildren[pid] = nil
    }

    /// SIGCONT every regular app (and its helpers) that is stopped but not in
    /// our own paused set, e.g. left over from a previous Maben Awake instance.
    private func thawStrays() {
        let apps = runningApps(fresh: true)
        let table = ProcessTable.current()
        let appPIDs = Set(apps.map(\.processIdentifier))
        for app in apps {
            let pid = app.processIdentifier
            guard !pausedPIDs.contains(pid) else { continue }
            for p in [pid] + table.helpers(of: pid, excluding: appPIDs) where Self.isStopped(p) { Signals.send(SIGCONT, to: p) }
        }
    }

    private static func isStopped(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status == UInt32(SSTOP)
    }

    /// The given pids plus all their parent processes up to launchd.
    private static func ancestors(of pids: [pid_t]) -> Set<pid_t> {
        var result = Set<pid_t>()
        for start in pids {
            var pid = start
            while pid > 1, result.insert(pid).inserted {
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
                pid = pid_t(info.pbi_ppid)
            }
        }
        return result
    }

    /// Offer the failsafe once per failsafe version to anyone using lid-closed
    /// mode, while someone is at the Mac (the password dialog needs a person).
    private func offerFailsafeIfNeeded(away: Bool) {
        guard !away, lidHelperInstalled, !failsafeInstalled, !installingFailsafe,
              Date().timeIntervalSince(startedAt) > 10,
              let bundled = Failsafe.bundledVersion,
              defaults.string(forKey: "failsafeOfferedVersion") != bundled
        else { return }
        EventLog.write("offering to install the lid-open failsafe")
        installFailsafe()
    }

    private func acquireAssertion() {
        guard assertionID == 0 else { return }
        let ok = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Maben Awake: keeping Mac awake for selected apps" as CFString,
            &assertionID
        )
        isAsserting = ok == kIOReturnSuccess
    }

    private func releaseAssertion() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isAsserting = false
    }

    private func acquireDisplayAssertion() {
        guard displayAssertionID == 0 else { return }
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Maben Awake: keeping the screen unlocked while the lid is closed" as CFString,
            &displayAssertionID
        )
    }

    private func releaseDisplayAssertion() {
        guard displayAssertionID != 0 else { return }
        IOPMAssertionRelease(displayAssertionID)
        displayAssertionID = 0
    }
}
