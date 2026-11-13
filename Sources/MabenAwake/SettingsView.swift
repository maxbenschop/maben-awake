import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, apps, lid, ai, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .apps: "Apps"
        case .lid: "Lid & Power"
        case .ai: "Agents"
        case .about: "About"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "When the Mac stays awake, and starting up."
        case .apps: "What happens to each app while the lid is closed."
        case .lid: "Keep working with the lid closed, safely."
        case .ai: "Connect Claude Code, Codex, Cursor and other agents."
        case .about: ""
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .apps: "square.grid.2x2.fill"
        case .lid: "laptopcomputer"
        case .ai: "sparkles"
        case .about: "info.circle.fill"
        }
    }
    /// Words the sidebar search matches, besides the title.
    var keywords: String {
        switch self {
        case .general: "keep awake manual login startup always on status"
        case .apps: "freeze frozen mode always while ai request reset shield"
        case .lid: "lid closed battery sleep failsafe brightness dim screen unlock lock locked heat away"
        case .ai: "agents claude code codex cursor gemini copilot opencode qwen droid devin windsurf augment kiro hooks awake command cli requests release log"
        case .about: "version log update website github"
        }
    }

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .general: GeneralPane()
        case .apps: AppsPane()
        case .lid: LidPane()
        case .ai: AIPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        MBPage(title: "General", subtitle: SettingsPane.general.subtitle) {
            StatusCard()

            MBSection(title: "Keep awake") {
                MBRow(icon: "sun.max.fill", title: "Keep the Mac awake by hand",
                      detail: "Even when no agent is working.") {
                    MBToggle(isOn: $model.keepAwake)
                }
                MBRow(icon: "app.badge.checkmark", title: "Only while an Always on app runs",
                      info: "Only apps you set to Always on yourself count. Protected defaults like Mail don't.") {
                    MBToggle(isOn: $model.onlyWhileCheckedRunning).disabled(!model.keepAwake)
                }
            }

            UpdatesSection()

            MBSection(title: "Startup") {
                MBRow(icon: "power", title: "Open at login",
                      info: "Also restarts Maben Awake within seconds if it crashes, and wakes any frozen apps.") {
                    MBToggle(isOn: $model.launchAtLogin)
                }
            }
        }
    }
}

/// Version, the Update button, and the two automatic-update switches.
struct UpdatesSection: View {
    @ObservedObject private var updater = Updater.shared
    @State private var showNotes = false

    var body: some View {
        MBSection(title: "Updates") {
            MBRow(icon: updater.available == nil ? "checkmark.seal.fill" : "arrow.down.circle.fill",
                  tint: updater.available == nil ? MB.text : MB.green,
                  title: title, detail: detail) {
                trailing
            }
            MBRow(icon: "arrow.triangle.2.circlepath", title: "Check for updates automatically",
                  info: "Asks GitHub for the latest release at start and every 6 hours. It's the only time Maben Awake connects to the internet.") {
                MBToggle(isOn: $updater.autoCheck)
            }
            MBRow(icon: "square.and.arrow.down.fill", title: "Install updates automatically",
                  info: "Only while the lid is open and no agent is working, so an update never interrupts a job. Every update is checked for the Maben signature and Apple's notarization before it's installed.") {
                MBToggle(isOn: $updater.autoInstall).disabled(!updater.autoCheck)
            }
        }
    }

    private var title: String {
        if let r = updater.available { return "Version \(r.version) is available" }
        return "Maben Awake \(updater.currentVersion)"
    }

    private var detail: String {
        switch updater.state {
        case .idle: return "Not checked yet."
        case .checking: return "Checking GitHub…"
        case .upToDate(let date): return "Up to date. Checked \(date.formatted(.relative(presentation: .named)))."
        case .available: return updater.canInstall ? "Installs in a few seconds, then restarts." : "Move the app to Applications to update."
        case .downloading(_, let p): return "Downloading… \(Int(p * 100))%"
        case .installing: return "Installing. Maben Awake restarts in a moment."
        case .failed(let message): return message
        }
    }

    @ViewBuilder private var trailing: some View {
        switch updater.state {
        case .available(let release):
            Button("What's new") { showNotes.toggle() }
                .buttonStyle(.mbQuiet)
                .popover(isPresented: $showNotes, arrowEdge: .bottom) { ReleaseNotes(release: release) }
            Button("Update") { updater.install() }.buttonStyle(.mbPrimary).disabled(!updater.canInstall)
        case .checking, .downloading, .installing:
            ProgressView().controlSize(.small)
        default:
            Button("Check now") { updater.check(userInitiated: true) }.buttonStyle(.mbQuiet)
        }
    }
}

private struct ReleaseNotes: View {
    let release: Updater.Release
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Maben Awake \(release.version)").font(.system(size: 13, weight: .semibold))
            ScrollView {
                Text((try? AttributedString(markdown: release.notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                     ?? AttributedString(release.notes))
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            Link("Open on GitHub", destination: release.page).font(.system(size: 12))
        }
        .frame(width: 320)
        .padding(16)
    }
}

/// What Maben Awake is doing right now, at the top of General.
private struct StatusCard: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        HStack(spacing: 14) {
            StateBadge(state: model.state, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.headline)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MB.text)
                Text(model.statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(MB.muted)
            }
            Spacer()
            if model.frozenCount > 0 {
                HStack(spacing: 5) {
                    FreezeGlyph(size: 11, lineWidth: 2.2)
                    Text("\(model.frozenCount) frozen")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MB.cold)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: MB.radius, style: .continuous)
                .fill(LinearGradient(colors: [MB.green.opacity(model.isAsserting ? 0.14 : 0.04), MB.card],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: MB.radius, style: .continuous)
            .strokeBorder(model.isAsserting ? MB.green.opacity(0.3) : MB.line))
    }
}

// MARK: - Apps

/// Name and icon of an installed app by bundle ID, looked up on disk once.
@MainActor
enum InstalledApp {
    private static var cache: [String: (name: String, icon: NSImage?)] = [:]
    static func lookup(_ id: String) -> (name: String, icon: NSImage?) {
        if let hit = cache[id] { return hit }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
        let info = (name: name, icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) })
        cache[id] = info
        return info
    }
}

struct AppsPane: View {
    @EnvironmentObject private var model: Model
    @State private var search = ""
    @State private var confirmReset = false
    @State private var showModes = false

    fileprivate struct Row: Identifiable {
        let bundleID: String
        let name: String
        let icon: NSImage?
        let running: Bool
        let frozen: Bool
        var id: String { bundleID }
    }

    /// Running apps plus apps with a remembered mode that aren't running.
    private var rows: [Row] {
        var seen = Set<String>()
        var rows: [Row] = []
        for app in model.apps where seen.insert(app.bundleID).inserted {
            rows.append(Row(bundleID: app.bundleID, name: app.name, icon: app.icon, running: true, frozen: app.isPaused))
        }
        for id in model.customizedBundleIDs where seen.insert(id).inserted {
            let info = InstalledApp.lookup(id)
            rows.append(Row(bundleID: id, name: info.name, icon: info.icon, running: false, frozen: false))
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        return rows
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        MBPage(title: "Apps", subtitle: SettingsPane.apps.subtitle) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    MBSearchField(placeholder: "Search apps", text: $search)
                    Button { showModes.toggle() } label: { Label("Modes", systemImage: "info.circle") }
                        .buttonStyle(.mbQuiet)
                        .popover(isPresented: $showModes, arrowEdge: .bottom) { ModesHelp() }
                    Button("Reset all") { confirmReset = true }
                        .buttonStyle(.mbQuiet)
                        .disabled(model.customizedBundleIDs.isEmpty)
                }
                MBSection {
                    if rows.isEmpty {
                        Text(search.isEmpty ? "No apps running" : "No apps match \u{201C}\(search)\u{201D}")
                            .font(.system(size: 13))
                            .foregroundStyle(MB.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 22)
                    }
                    ForEach(rows) { row in AppRow(row: row) }
                }
                HStack(spacing: 6) {
                    Image(systemName: "shield.lefthalf.filled")
                    Text("Calls, music, passwords, VPNs, terminals and editors are Always on by default.")
                }
                .font(.system(size: 12))
                .foregroundStyle(MB.dim)
            }
        }
        .confirmationDialog("Reset every app to its default mode?", isPresented: $confirmReset) {
            Button("Reset All", role: .destructive) { model.resetAllModes() }
        } message: {
            Text("Protected apps go back to Always on; all others to When AI asks.")
        }
    }
}

private struct ModesHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(AppMode.allCases) { mode in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: mode.symbol).font(.system(size: 12, weight: .semibold)).frame(width: 16).foregroundStyle(MB.text)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(MB.text)
                        Text(mode.explanation.replacingOccurrences(of: "`", with: ""))
                            .font(.system(size: 12)).foregroundStyle(MB.muted)
                    }
                }
            }
        }
        .frame(width: 270, alignment: .leading)
        .padding(16)
    }
}

private struct AppRow: View {
    @EnvironmentObject private var model: Model
    let row: AppsPane.Row
    @State private var hovering = false

    var body: some View {
        let custom = model.customizedBundleIDs.contains(row.bundleID)
        HStack(spacing: 12) {
            AppIcon(image: row.icon, size: 26)
                .opacity(row.running ? 1 : 0.45)
                .saturation(row.frozen ? 0 : 1)
            HStack(spacing: 6) {
                Text(row.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(row.frozen ? MB.muted : MB.text)
                    .lineLimit(1)
                if row.frozen {
                    HStack(spacing: 4) {
                        FreezeGlyph(size: 10, lineWidth: 2.3)
                        Text("Frozen")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MB.cold)
                } else if !row.running {
                    Text("Not running").font(.system(size: 11)).foregroundStyle(MB.dim)
                }
                if custom { Tag(text: "Custom") }
            }
            Spacer()
            MBModeMenu(bundleID: row.bundleID, custom: custom)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(hovering ? Color.white.opacity(0.025) : .clear)
        .onHover { hovering = $0 }
    }
}

private struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(MB.muted)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(Color.white.opacity(0.07)))
    }
}

/// The mode of one app: a Maben pill that opens the three modes and "Back to default".
private struct MBModeMenu: View {
    @EnvironmentObject private var model: Model
    let bundleID: String
    let custom: Bool

    var body: some View {
        let mode = model.mode(of: bundleID)
        let protected = model.isProtectedByDefault(bundleID)
        Menu {
            ForEach(AppMode.allCases) { option in
                Button { model.setMode(bundleID: bundleID, option) } label: {
                    Label(option.label, systemImage: option == mode ? "checkmark" : option.symbol)
                }
            }
            if custom {
                Divider()
                Button("Back to default (\(protected ? AppMode.always.label : AppMode.onDemand.label))") { model.resetMode(bundleID) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: protected && mode == .always ? "shield.lefthalf.filled" : mode.symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(mode.shortLabel).font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(MB.dim)
            }
            .foregroundStyle(MB.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(MB.line))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Lid & Power

struct LidPane: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        MBPage(title: "Lid & Power", subtitle: SettingsPane.lid.subtitle) {
            MBSection(title: "Lid closed",
                      footer: model.lidSleepDisabled ? "Right now, closing the lid won't sleep the Mac."
                                                     : "Right now, closing the lid sleeps the Mac.") {
                if model.lidHelperInstalled {
                    MBRow(icon: "laptopcomputer", title: "Stay awake with the lid closed",
                          info: "Only while Maben Awake is keeping the Mac awake. Quitting always restores normal lid sleep.") {
                        MBToggle(isOn: $model.lidClosedMode)
                    }
                    MBRow(icon: "battery.25percent", title: "Sleep anyway below",
                          detail: "So a laptop in a bag never drains to zero.") {
                        MBSegmented(options: [5, 10, 20, 30], selection: $model.batteryCutoff) { "\($0)%" }
                            .disabled(!model.lidClosedMode)
                    }
                } else {
                    MBRow(icon: "laptopcomputer", title: "Stay awake with the lid closed",
                          detail: "Asks for your password once.",
                          info: "macOS ignores keep-awake requests when the lid closes. Setup lets Maben Awake run exactly one command, pmset disablesleep, without asking you again.") {
                        Button("Set up") { model.installLidHelper() }.buttonStyle(.mbPrimary)
                    }
                }
            }

            MBSection(title: "While the lid is closed",
                      footer: "With an external display connected, nothing is frozen or dimmed. If the Mac gets seriously hot, it sleeps to cool down.") {
                MBRow(icon: "maben.freeze", title: "Freeze apps no agent needs",
                      detail: "Frozen apps use no CPU.") {
                    MBToggle(isOn: $model.pauseOthers)
                }
                MBRow(icon: "sun.min.fill", title: "Turn the screen down to 0",
                      detail: Brightness.isAvailable ? "Restored when the lid opens." : "Not available on this Mac.") {
                    MBToggle(isOn: $model.dimWhenClosed).disabled(!Brightness.isAvailable)
                }
                MBRow(icon: "lock.open.fill", title: "Keep the screen unlocked",
                      detail: "So an agent can still click in apps.",
                      info: "Without it, macOS locks the screen after about half an hour and an agent can no longer click in apps.") {
                    MBToggle(isOn: $model.keepUnlockedWhenClosed)
                }
                MBRow(icon: "lock.fill", title: "Lock the screen when you open the lid",
                      detail: "So whoever opens it has to log in.",
                      info: "Only after the screen was kept unlocked with the lid closed. Without Maben Awake, macOS would have locked it.") {
                    MBToggle(isOn: $model.lockWhenLidOpens).disabled(!model.keepUnlockedWhenClosed)
                }
            }

            MBSection(title: "While the screen is locked",
                      footer: LidControl.hasLid ? "For when you lock the Mac and walk away with the lid open."
                                                : "This Mac has no lid, so a locked screen is how Maben Awake knows you're away.") {
                MBRow(icon: "lock.display", title: "Freeze apps while the screen is locked",
                      detail: "Treated like a closed lid: apps no agent needs are frozen.",
                      info: "The screen isn't dimmed and stays locked. Unlocking it wakes every frozen app.") {
                    MBToggle(isOn: $model.freezeWhileLocked).disabled(!model.pauseOthers)
                }
            }

            MBSection(title: "Safety") {
                MBRow(icon: "checkmark.shield.fill", title: "Lid-open failsafe",
                      detail: "Brings the screen back if the app gets stuck.",
                      info: "A small separate service watches the lid. When you open it, it turns the screen back on and wakes apps, even if Maben Awake itself is stuck. Asks for your password once.") {
                    if model.failsafeInstalled {
                        MBStatus(kind: .ok, text: "On")
                    } else {
                        Button(model.installingFailsafe ? "Installing…" : "Install") { model.installFailsafe() }
                            .buttonStyle(.mbPrimary)
                            .disabled(model.installingFailsafe || Failsafe.bundledBinary == nil)
                    }
                }
                MBRow(icon: "list.bullet.rectangle", title: "Event log",
                      detail: "Why the Mac stayed awake, or slept.") {
                    Button("Open") { Integration.open(EventLog.url) }.buttonStyle(.mbQuiet)
                }
            }
        }
    }
}

// MARK: - Agents

struct AIPane: View {
    @EnvironmentObject private var model: Model
    @State private var cliPath = Integration.cliPath
    @State private var cliStatus = Integration.cliStatus
    @State private var hooked = Integration.hookedSettingsFiles
    @State private var hooksStatus = Integration.hooksStatus
    @State private var agents = Integration.presentAgents.map { ($0, Integration.status(of: $0)) }
    @State private var problem: String?
    @State private var busy = false
    @State private var justChanged: String?

    private var canInstall: Bool { Integration.isInApplications }

    private func refresh() {
        cliPath = Integration.cliPath
        cliStatus = Integration.cliStatus
        hooked = Integration.hookedSettingsFiles
        hooksStatus = Integration.hooksStatus
        agents = Integration.presentAgents.map { ($0, Integration.status(of: $0)) }
    }

    private func flash(_ id: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { justChanged = id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.3)) { if justChanged == id { justChanged = nil } }
        }
    }

    private func set(_ agent: Integration.Agent, install: Bool) {
        do {
            if install { try Integration.install(agent) } else { try Integration.remove(agent) }
            problem = nil
            flash(agent.id)
        } catch { problem = error.localizedDescription }
        refresh()
    }

    /// Agents that aren't set up on this Mac, for the note under the list.
    private var otherAgents: String {
        Integration.agents.filter { agent in !agents.contains { $0.0.id == agent.id } }
            .map { $0.tested ? $0.name : $0.name + " (not tested yet)" }.joined(separator: ", ")
    }

    private func setHooks(install: Bool) {
        do {
            if install { try Integration.installHooks() } else { try Integration.removeHooks() }
            problem = nil
            flash("claude")
        } catch { problem = error.localizedDescription }
        refresh()
    }

    private func setCLI(install: Bool) {
        busy = true
        let done: @MainActor (Bool) -> Void = { ok in
            busy = false
            problem = ok ? nil : (install ? "The awake command wasn't added." : "The awake command wasn't removed.")
            if ok { flash("cli") }
            refresh()
        }
        if install { Integration.installCLI(completion: done) } else { Integration.removeCLI(completion: done) }
    }

    var body: some View {
        MBPage(title: "Agents", subtitle: SettingsPane.ai.subtitle) {
            if let problem {
                Notice(text: problem)
            } else if !canInstall {
                Notice(text: "Move Maben Awake to your Applications folder and open it from there to connect your agents.")
            }

            MBSection(title: "Connections",
                      footer: hooksStatus == .outdated || cliStatus == .outdated || agents.contains { $0.1 == .outdated }
                        ? "Outdated means it points at another copy of the app. Update moves it to this one."
                        : otherAgents.isEmpty ? nil : "Also works with \(otherAgents). They appear here once they're set up on this Mac.") {
                IntegrationRow(image: BrandLogo.claude, title: "Claude Code",
                               detail: hooked.isEmpty ? "Keeps the Mac awake while Claude Code works."
                                    : hooked.count == 1 ? "Connected in \(Integration.tilde(hooked[0]))" : "Connected in \(hooked.count) places",
                               reveal: hooked.first, status: hooksStatus, enabled: canInstall,
                               flashing: justChanged == "claude") { setHooks(install: $0) }
                ForEach(agents, id: \.0.id) { agent, status in
                    IntegrationRow(image: agent.id == "codex" ? BrandLogo.openAI : nil, icon: agent.id == "codex" ? nil : "sparkles",
                                   title: agent.name,
                                   detail: (agent.tested ? "" : "Not tested yet. ")
                                        + (status == .installed ? agent.afterConnecting ?? "Connected in \(Integration.tilde(Integration.file(of: agent)))"
                                           : "Keeps the Mac awake while it works."),
                                   reveal: status == .missing ? nil : Integration.file(of: agent), status: status,
                                   enabled: canInstall, flashing: justChanged == agent.id) { set(agent, install: $0) }
                }
                IntegrationRow(icon: "terminal.fill", title: "awake command",
                               detail: cliPath.map { Integration.tilde(URL(fileURLWithPath: $0)) } ?? "For scripts and other tools.",
                               reveal: nil, status: cliStatus, enabled: canInstall && !busy,
                               flashing: justChanged == "cli") { setCLI(install: $0) }
            }

            MBSection(title: "Right now") {
                if model.leases.isEmpty {
                    Text("No agent is keeping the Mac awake.")
                        .font(.system(size: 13))
                        .foregroundStyle(MB.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else if onScreen {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in leaseRows }
                } else {
                    leaseRows
                }
            }

            MBSection(title: "The awake command") {
                MBCommandRow(command: "awake run tests -- npm test", detail: "Stay awake while a command runs")
                MBCommandRow(command: "awake hold build 30", detail: "Stay awake for 30 minutes")
                MBCommandRow(command: "awake need Dia", detail: "Wake a frozen app for 10 minutes")
                MBCommandRow(command: "awake log", detail: "Why the Mac stayed awake, or slept")
            }

            HStack(spacing: 8) {
                Button("Hook log") { Integration.open(Integration.hooksLog) }.buttonStyle(.mbQuiet)
                Button("Event log") { Integration.open(EventLog.url) }.buttonStyle(.mbQuiet)
                Button("Requests folder") { NSWorkspace.shared.open(LeaseStore.directory) }.buttonStyle(.mbQuiet)
                Spacer()
                if !model.leases.isEmpty {
                    Button("Release all") { model.releaseAllLeases() }.buttonStyle(.mbDanger)
                }
            }
        }
        .onAppear { refresh() }
    }

    @Environment(\.windowOnScreen) private var onScreen

    private var leaseRows: some View {
        VStack(spacing: 0) {
            ForEach(model.leases) { lease in
                MBRow(icon: lease.symbol, title: lease.title) {
                    Text(lease.detail)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(MB.muted)
                    Button("Release") { model.release(lease) }.buttonStyle(.mbQuiet)
                }
            }
        }
    }
}

/// A connection with its status, one action, and a short confirmation when it changes.
private struct IntegrationRow: View {
    var image: NSImage? = nil
    var icon: String? = nil
    let title: String
    let detail: String
    let reveal: URL?
    let status: Integration.Status
    let enabled: Bool
    let flashing: Bool
    let action: (Bool) -> Void

    var body: some View {
        MBRow(icon: icon, image: image, title: title, detail: detail) {
            HStack(spacing: 10) {
                if let reveal {
                    Button { Integration.reveal(reveal) } label: { Image(systemName: "folder").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(MB.dim)
                        .help("Show in Finder")
                }
                if flashing {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(MB.green)
                        .font(.system(size: 15))
                        .transition(.scale.combined(with: .opacity))
                } else {
                    MBStatus(kind: status == .installed ? .ok : status == .outdated ? .warn : .off,
                             text: status == .installed ? "Connected" : status == .outdated ? "Outdated" : "Off")
                        .transition(.opacity)
                }
                switch status {
                case .missing: Button("Connect") { action(true) }.buttonStyle(.mbPrimary).disabled(!enabled)
                case .outdated: Button("Update") { action(true) }.buttonStyle(.mbPrimary).disabled(!enabled)
                case .installed: Button("Remove") { action(false) }.buttonStyle(.mbQuiet)
                }
            }
        }
    }
}

private struct Notice: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(MB.orange)
            Text(text).font(.system(size: 12.5)).foregroundStyle(MB.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: MB.radius, style: .continuous).fill(MB.orange.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: MB.radius, style: .continuous).strokeBorder(MB.orange.opacity(0.3)))
    }
}

// MARK: - About

struct AboutPane: View {
    private var short: String { Updater.shared.currentVersion }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: MB.green.opacity(0.25), radius: 24, y: 8)
                MBWordmark(size: 22).padding(.top, 18)
                HStack(spacing: 8) {
                    Text("Version \(short)").textSelection(.enabled)
                    Text("·")
                    Button("Check for updates") { Updater.shared.check(userInitiated: true) }
                        .buttonStyle(.plain)
                        .foregroundStyle(MB.green)
                }
                .font(.system(size: 12))
                .foregroundStyle(MB.dim)
                .padding(.top, 8)

                if !WhatsNew.items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("New in this version").font(.system(size: 12, weight: .semibold)).foregroundStyle(MB.dim)
                    ForEach(WhatsNew.items, id: \.self) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(MB.green).frame(width: 5, height: 5).padding(.top, 6)
                            Text(item).font(.system(size: 12.5)).foregroundStyle(MB.text).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
                .frame(width: 400, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: MB.radius, style: .continuous).fill(MB.card))
                .overlay(RoundedRectangle(cornerRadius: MB.radius, style: .continuous).strokeBorder(MB.line))
                .padding(.top, 24)
                }

                HStack(spacing: 8) {
                    Link(destination: URL(string: "https://awake.maben.gg")!) { Text("Website") }.buttonStyle(.mbPrimary)
                    Link(destination: URL(string: "https://awake.maben.gg/changelog/")!) { Text("Changelog") }.buttonStyle(.mbQuiet)
                    Link(destination: URL(string: "https://github.com/maxbenschop/maben-awake")!) { Text("GitHub") }.buttonStyle(.mbQuiet)
                }
                .padding(.top, 20)
                Text("© 2026 Maben · MIT licence")
                    .font(.system(size: 11))
                    .foregroundStyle(MB.dim)
                    .padding(.top, 22)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 44)
            .padding(.bottom, 32)
        }
    }
}

/// This version's entry in CHANGELOG.md (bundled with the app), shown on About.
enum WhatsNew {
    static let items: [String] = {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        var inSection = false, items: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                if inSection { break }
                inSection = line.dropFirst(3).hasPrefix(version + " ")
            } else if inSection, line.hasPrefix("- ") {
                items.append(String(line.dropFirst(2)).replacingOccurrences(of: "`", with: ""))
            }
        }
        return items
    }()
}
