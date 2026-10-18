import AppKit
import Combine
import IOKit.pwr_mgt
import ServiceManagement

/// How Sleepwalker treats an app while it's keeping the Mac awake.
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
    /// Also stay awake with the lid closed (needs the one-time helper).
    @Published var lidClosedMode: Bool {
        didSet { defaults.set(lidClosedMode, forKey: "lidClosedMode"); apply() }
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
    /// Start at login and restart automatically after a crash.
    @Published var launchAtLogin: Bool = false {
        didSet {
            defaults.set(launchAtLogin, forKey: "wantAgent")
            guard launchAtLogin != (Instance.isEnabled) else { return }
            let actual = Instance.setEnabled(launchAtLogin)
            if actual != launchAtLogin { launchAtLogin = actual }
        }
    }
    /// Lid closed and no external display: nobody is at the Mac.
    @Published private(set) var away = false
    /// Mac got too hot while away; we stopped keeping it awake so it can sleep.
    @Published private(set) var overheated = false
    /// Set when this run started after the previous one crashed.
    @Published private(set) var recoveredFromCrash = false

    private let defaults = UserDefaults.standard
    private var assertionID: IOPMAssertionID = 0
    private var pausedPIDs = Set<pid_t>()
    /// Helper processes (browser tabs, Electron helpers…) frozen with each app.
    private var pausedChildren: [pid_t: [pid_t]] = [:]
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
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        keepAwake = defaults.bool(forKey: "keepAwake")
        onlyWhileCheckedRunning = defaults.bool(forKey: "onlyWhileCheckedRunning")
        pauseOthers = defaults.bool(forKey: "pauseOthers")
        lidClosedMode = defaults.object(forKey: "lidClosedMode") as? Bool ?? true
        dimWhenClosed = defaults.object(forKey: "dimWhenClosed") as? Bool ?? true
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
                self?.userResumed.remove(app.processIdentifier)
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

        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.apply() }
        }
        apply()
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
        lidHelperInstalled = LidControl.installHelper()
        appliedLidSleepDisabled = nil
        apply()
    }

    func release(_ lease: Lease) { LeaseStore.remove(lease); apply() }
    func releaseAllLeases() { LeaseStore.removeAll(); apply() }

    /// Why the Mac is currently being kept awake, for the status line.
    var statusText: String {
        if overheated { return "Mac got too hot with the lid closed, so it was allowed to sleep" }
        if !isAsserting { return "Mac may sleep normally" }
        let lid: String
        if !lidSleepDisabled { lid = "" }
        else if away { lid = " · lid closed, apps frozen" }
        else if lidClosed { lid = " · external display, nothing frozen" }
        else { lid = " · lid closed OK" }
        if !leases.isEmpty {
            let names = leases.map(\.name).joined(separator: ", ")
            return "Kept awake by \(names)\(lid)"
        }
        return "Mac is being kept awake\(lid)"
    }

    /// Resume everything we paused. Called before quitting.
    func shutdown() {
        for pid in pausedPIDs { resume(pid: pid) }
        releaseAssertion()
        LidControl.setSleepDisabled(false)
        restoreBrightness()
        defaults.set(false, forKey: "running")
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

    private func runningApps() -> [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && $0.processIdentifier != me
                && $0.bundleIdentifier != "com.apple.finder"
                && $0.bundleIdentifier != nil
        }
    }

    private func apply() {
        let running = runningApps()
        let currentLeases = LeaseStore.active()
        if currentLeases != leases { leases = currentLeases }

        // 1. Should we be holding the Mac awake right now?
        //    Either the manual toggle says so, or an external tool holds a lease.
        // Only apps the user explicitly set to "Always on" count here, not the
        // protected defaults (an open Mail shouldn't keep the Mac awake).
        let anyCheckedRunning = running.contains { checked.contains($0.bundleIdentifier!) }
        let manual = keepAwake && (!onlyWhileCheckedRunning || anyCheckedRunning)

        // Away = lid closed and no external display (clamshell mode means the
        // user is working on the external screen, so nothing is frozen or dimmed).
        let closed = LidControl.isLidClosed
        let nowAway = closed && !LidControl.externalDisplayActive
        if closed != lidClosed { lidClosed = closed }
        if nowAway != away { away = nowAway }

        // Heat check: a closed laptop (e.g. in a bag) that gets seriously hot is
        // allowed to sleep. Cleared once someone is back at the Mac.
        let thermal = (defaults.object(forKey: "testThermalState") as? Int)
            .flatMap(ProcessInfo.ThermalState.init(rawValue:)) ?? ProcessInfo.processInfo.thermalState
        let heatApplies = nowAway || defaults.object(forKey: "testThermalState") != nil
        if heatApplies && thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            if !overheated {
                overheated = true
                EventLog.write("thermal state \(thermal.rawValue) while lid closed: releasing keep-awake so the Mac can sleep")
            }
        } else if !heatApplies && overheated {
            overheated = false
            EventLog.write("back at the Mac: heat cutoff cleared")
        }

        let shouldAssert = (manual || !currentLeases.isEmpty) && !overheated
        shouldAssert ? acquireAssertion() : releaseAssertion()

        // 2. Closed-lid sleep: only blocked while we're keeping the Mac awake,
        //    and never on a nearly empty battery.
        let wantLid = shouldAssert && lidClosedMode && lidHelperInstalled && !LidControl.batteryBelow(10)
        if wantLid != appliedLidSleepDisabled {
            if LidControl.setSleepDisabled(wantLid) || !wantLid { appliedLidSleepDisabled = wantLid }
            lidSleepDisabled = wantLid && appliedLidSleepDisabled == true
        }

        // 3. Away transitions: dim the screen while away, restore when back.
        if nowAway != lastAway {
            lastAway = nowAway
            if nowAway { if dimWhenClosed { dimScreen() } } else { restoreBrightness(); thawStrays() }
        }

        // 4. Pause / resume the other apps. Only while away: otherwise the user
        //    may click any app at any moment.
        let shouldPause = shouldAssert && pauseOthers && nowAway
        // Apps an AI is running inside (terminal, editor, T3…) are never frozen.
        let aiHosts = Self.ancestors(of: currentLeases.map(\.owner).filter { $0 > 0 })
        let working = aiWorking

        // Quit apps the AI launched / close tabs it opened, once it's done.
        let requestedApps = Set(currentLeases.compactMap(\.app).map { $0.lowercased() })
        // `testCleanupWithLidOpen` lets tests exercise cleanup without closing the lid.
        let cleanupLid = nowAway || defaults.bool(forKey: "testCleanupWithLidOpen")
        let cleaningUp = cleanup.update(requested: requestedApps, lidClosed: cleanupLid) { want in
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
        for app in running {
            let pid = app.processIdentifier
            // Apps the user clicked are left alone until they've been in the
            // background for a minute.
            if userResumed.contains(pid), pid != frontmost,
               let left = leftFrontAt[pid], left.timeIntervalSinceNow < -60 {
                userResumed.remove(pid)
            }
            let needed: Bool
            switch mode(of: app.bundleIdentifier!) {
            case .always: needed = true
            case .whileAI: needed = working || isRequested(app)
            case .onDemand: needed = isRequested(app)
            }
            let userIsUsingIt = userPresent && (pid == frontmost || userResumed.contains(pid))
            // Never freeze an app that is still starting up: frozen mid-launch it
            // finishes launching (and grabs focus) whenever it's next woken.
            let starting = !app.isFinishedLaunching
                || (app.launchDate.map { $0.timeIntervalSinceNow > -15 } ?? false)
            if !shouldPause || needed || userIsUsingIt || starting || cleaningUp.contains(pid) || aiHosts.contains(pid) {
                resume(pid: pid)
            } else {
                pause(pid: pid)
            }
        }

        // 5. Refresh the list for the UI.
        let entries = running.map {
            AppEntry(
                id: $0.processIdentifier,
                bundleID: $0.bundleIdentifier!,
                name: $0.localizedName ?? $0.bundleIdentifier!,
                icon: $0.icon,
                isPaused: pausedPIDs.contains($0.processIdentifier)
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if entries != apps { apps = entries }
    }

    private func userActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pausedPIDs.contains(pid) else { return }
        resume(pid: pid)
        userResumed.insert(pid)
        apply()
    }

    private func pause(pid: pid_t) {
        guard !pausedPIDs.contains(pid) else { return }
        // Stop the app first so it can't spawn new helpers, then its helpers.
        guard kill(pid, SIGSTOP) == 0 else { return }
        pausedPIDs.insert(pid)
        let children = Self.descendants(of: pid)
        for child in children { kill(child, SIGSTOP) }
        pausedChildren[pid] = children
    }

    private func resume(pid: pid_t) {
        guard pausedPIDs.contains(pid) else { return }
        for child in pausedChildren[pid] ?? [] { kill(child, SIGCONT) }
        kill(pid, SIGCONT)
        pausedPIDs.remove(pid)
        pausedChildren[pid] = nil
    }

    /// SIGCONT every regular app (and its helpers) that is stopped but not in
    /// our own paused set, e.g. left over from a previous Sleepwalker instance.
    private func thawStrays() {
        for app in runningApps() {
            let pid = app.processIdentifier
            guard !pausedPIDs.contains(pid) else { continue }
            for p in [pid] + Self.descendants(of: pid) where Self.isStopped(p) { kill(p, SIGCONT) }
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

    /// All child processes of `pid`, recursively.
    private static func descendants(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 1024)
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        let children = buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
        return children + children.flatMap { descendants(of: $0) }
    }

    private func acquireAssertion() {
        guard assertionID == 0 else { return }
        let ok = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Sleepwalker: keeping Mac awake for selected apps" as CFString,
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
}
