import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, apps, lid, ai, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .apps: "Apps"
        case .lid: "Lid & Power"
        case .ai: "AI"
        case .about: "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .apps: "square.grid.2x2"
        case .lid: "laptopcomputer"
        case .ai: "sparkles"
        case .about: "info.circle"
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

private let paneWidth: CGFloat = 520

// MARK: - General

struct GeneralPane: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.keepAwake) {
                    Text("Keep Mac awake manually")
                    Text("Without this, Maben Awake only keeps the Mac awake while an AI asks for it.")
                }
                Toggle(isOn: $model.onlyWhileCheckedRunning) {
                    Text("Only while an \"Always on\" app is running")
                    Text("Apps you set to Always on yourself count; protected defaults like Mail don't.")
                }
                .disabled(!model.keepAwake)
            } header: {
                Text("Keep Awake")
            } footer: {
                StatusLine()
            }

            Section("Startup") {
                Toggle(isOn: $model.launchAtLogin) {
                    Text("Open at login")
                    Text("Also restarts Maben Awake within seconds if it crashes, thawing any frozen apps.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StatusLine: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        HStack(spacing: 8) {
            StateBadge(state: model.state, size: 18)
            Text("\(model.headline) · \(model.statusText)")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Apps

struct AppsPane: View {
    @EnvironmentObject private var model: Model
    @State private var search = ""
    @State private var confirmReset = false

    private struct Row: Identifiable {
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
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
            let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            rows.append(Row(bundleID: id, name: name, icon: icon, running: false, frozen: false))
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        return rows
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose what happens to each app while the lid is closed and Maben Awake keeps the Mac awake.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    ForEach(AppMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(mode.explanation.replacingOccurrences(of: "`", with: ""))
                    }
                    Spacer()
                }
                SearchField(text: $search)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            List {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        AppIcon(image: row.icon, size: 24)
                            .opacity(row.running ? 1 : 0.55)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(row.name).lineLimit(1)
                                if row.frozen {
                                    Image(systemName: "snowflake").font(.caption).foregroundStyle(.cyan)
                                        .help("Frozen right now")
                                }
                            }
                            Text(row.running ? row.bundleID : "Not running · \(row.bundleID)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if model.customizedBundleIDs.contains(row.bundleID) {
                            Button {
                                model.resetMode(row.bundleID)
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Back to the default mode")
                        }
                        ModeMenu(bundleID: row.bundleID)
                            .frame(width: 112, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                }
                if rows.isEmpty {
                    Text(search.isEmpty ? "No apps" : "No apps match \"\(search)\"")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(height: 300)
            .overlay(alignment: .top) { Divider() }

            HStack {
                Label("Shielded apps (calls, audio, passwords, VPN, terminals and editors) are Always on by default.",
                      systemImage: "shield.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset All…") { confirmReset = true }
                    .disabled(model.customizedBundleIDs.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: paneWidth)
        .confirmationDialog("Reset every app to its default mode?", isPresented: $confirmReset) {
            Button("Reset All", role: .destructive) { model.resetAllModes() }
        } message: {
            Text("Protected apps go back to Always on; all others to When AI asks.")
        }
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search apps", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Lid & Power

struct LidPane: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        Form {
            Section {
                if model.lidHelperInstalled {
                    Toggle(isOn: $model.lidClosedMode) {
                        Text("Stay awake with the lid closed")
                        Text("Only while Maben Awake is keeping the Mac awake. Quitting always restores normal lid sleep.")
                    }
                    Picker(selection: $model.batteryCutoff) {
                        ForEach([5, 10, 20, 30], id: \.self) { Text("Below \($0)%").tag($0) }
                    } label: {
                        Text("Allow lid sleep on battery")
                        Text("So a closed laptop in a bag doesn't drain to zero.")
                    }
                    .disabled(!model.lidClosedMode)
                } else {
                    LabeledContent {
                        Button("Set Up…") { model.installLidHelper() }
                    } label: {
                        Text("Stay awake with the lid closed")
                        Text("macOS ignores keep-awake requests when the lid closes. Setup asks for your password once and allows only `pmset disablesleep`.")
                    }
                }
            } header: {
                Text("Lid Closed")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    if model.lidSleepDisabled {
                        Label("Right now, closing the lid won't sleep the Mac.", systemImage: "checkmark.seal.fill")
                    } else {
                        Label("Right now, closing the lid sleeps the Mac.", systemImage: "moon.zzz")
                    }
                    Spacer()
                    Button("Show Log") { Integration.open(EventLog.url) }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    if model.failsafeInstalled {
                        Label("On", systemImage: "checkmark.seal.fill").foregroundStyle(.secondary)
                    } else {
                        Button(model.installingFailsafe ? "Installing…" : "Install…") { model.installFailsafe() }
                            .disabled(model.installingFailsafe || Failsafe.bundledBinary == nil)
                    }
                } label: {
                    Text("Lid-open failsafe")
                    Text("A small background service that turns the screen back on and unfreezes apps when you open the lid, even if Maben Awake gets stuck. Asks for your password once.")
                }
            } header: {
                Text("Safety")
            }

            Section {
                Toggle(isOn: $model.pauseOthers) {
                    Text("Freeze apps no AI needs")
                    Text("Frozen apps use no CPU. Opening the lid thaws everything. Set modes per app in Apps.")
                }
                Toggle(isOn: $model.dimWhenClosed) {
                    Text("Turn screen brightness to 0")
                    Text(Brightness.isAvailable
                         ? "Restored when the lid opens."
                         : "Brightness control isn't available on this Mac.")
                }
                .disabled(!Brightness.isAvailable)
                Toggle(isOn: $model.keepUnlockedWhenClosed) {
                    Text("Keep the screen unlocked")
                    Text("Stops the display from idle-sleeping, which is what makes macOS lock the screen. Without it, an AI can't click in apps after about half an hour.")
                }
            } header: {
                Text("While the Lid Is Closed")
            } footer: {
                Text("With an external display connected, nothing is frozen or dimmed. If the Mac gets seriously hot with the lid closed, Maben Awake lets it sleep to cool down.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - AI

struct AIPane: View {
    @EnvironmentObject private var model: Model
    @State private var cliPath = Integration.cliPath
    @State private var cliStatus = Integration.cliStatus
    @State private var hooked = Integration.hookedSettingsFiles
    @State private var hooksStatus = Integration.hooksStatus
    @State private var codexStatus = Integration.codexStatus
    @State private var problem: String?
    @State private var busy = false

    private var canInstall: Bool { Integration.isInApplications }

    private func refresh() {
        cliPath = Integration.cliPath
        cliStatus = Integration.cliStatus
        hooked = Integration.hookedSettingsFiles
        hooksStatus = Integration.hooksStatus
        codexStatus = Integration.codexStatus
    }

    private func setCodex(install: Bool) {
        do {
            if install { try Integration.installCodexHooks() } else { try Integration.removeCodexHooks() }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        refresh()
    }

    private func setHooks(install: Bool) {
        do {
            if install { try Integration.installHooks() } else { try Integration.removeHooks() }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        refresh()
    }

    private func setCLI(install: Bool) {
        busy = true
        let done: @MainActor (Bool) -> Void = { ok in
            busy = false
            problem = ok ? nil : (install ? "The awake command wasn't added." : "The awake command wasn't removed.")
            refresh()
        }
        if install { Integration.installCLI(completion: done) } else { Integration.removeCLI(completion: done) }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    StatusPill(status: hooksStatus)
                    switch hooksStatus {
                    case .missing: Button("Install") { setHooks(install: true) }.disabled(!canInstall)
                    case .outdated: Button("Update") { setHooks(install: true) }.disabled(!canInstall)
                    case .installed: Button("Remove") { setHooks(install: false) }
                    }
                } label: {
                    Text("Claude Code hooks")
                    Text(hooked.isEmpty
                         ? "Keeps the Mac awake while Claude Code works (also inside T3 Code). Adds five entries to ~/.claude/settings.json."
                         : hooked.map(Integration.tilde).joined(separator: ", "))
                }
                LabeledContent {
                    StatusPill(status: codexStatus)
                    switch codexStatus {
                    case .missing: Button("Install") { setCodex(install: true) }.disabled(!canInstall)
                    case .outdated: Button("Update") { setCodex(install: true) }.disabled(!canInstall)
                    case .installed: Button("Remove") { setCodex(install: false) }
                    }
                } label: {
                    Text("Codex hooks")
                    Text(codexStatus == .installed
                         ? "~/.codex/hooks.json. In Codex, run /hooks once and trust them."
                         : Integration.codexPresent ? "Keeps the Mac awake while Codex works. Adds entries to ~/.codex/hooks.json."
                                                    : "For OpenAI's Codex. Install it when you start using Codex.")
                }
                LabeledContent {
                    StatusPill(status: cliStatus)
                    switch cliStatus {
                    case .missing: Button("Install") { setCLI(install: true) }.disabled(!canInstall || busy)
                    case .outdated: Button("Update") { setCLI(install: true) }.disabled(!canInstall || busy)
                    case .installed: Button("Remove") { setCLI(install: false) }.disabled(busy)
                    }
                } label: {
                    Text("awake command")
                    Text(cliPath ?? "For scripts and other AI tools: awake run, awake hold, awake need.")
                }
            } header: {
                Text("Integration")
            } footer: {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !canInstall {
                    Label("Move Maben Awake to your Applications folder and open it from there to install these.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if hooksStatus == .outdated || cliStatus == .outdated {
                    Text("Outdated means it points at another copy of the app. Update moves it to this one.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section("Active Requests") {
                if model.leases.isEmpty {
                    Text("No AI is holding the Mac awake right now.")
                        .foregroundStyle(.secondary)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        VStack(spacing: 8) {
                            ForEach(model.leases) { lease in
                                HStack {
                                    Label(lease.title, systemImage: lease.symbol)
                                    Spacer()
                                    Text(lease.detail).monospacedDigit().foregroundStyle(.secondary)
                                    Button("Release") { model.release(lease) }
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                    Button("Release All") { model.releaseAllLeases() }
                }
            }

            Section {
                CommandRow(command: "awake need Dia", detail: "Unfreeze an app for 10 minutes")
                CommandRow(command: "awake run tests -- npm test", detail: "Stay awake while a command runs")
                CommandRow(command: "awake hold build 30", detail: "Stay awake for 30 minutes")
                CommandRow(command: "awake list", detail: "Show active requests")
                CommandRow(command: "awake log", detail: "Why the Mac was kept awake, or slept")
            } header: {
                Text("Commands")
            }

            Section {
                HStack {
                    Button("Show Hook Log") { Integration.open(Integration.hooksLog) }
                    Button("Show Event Log") { Integration.open(EventLog.url) }
                    Spacer()
                    Button("Open Requests Folder") { NSWorkspace.shared.open(LeaseStore.directory) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { refresh() }
    }
}

private struct StatusPill: View {
    let status: Integration.Status
    var body: some View {
        Label(status == .installed ? "Installed" : status == .outdated ? "Outdated" : "Not installed",
              systemImage: status == .installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(status == .installed ? .green : .orange)
    }
}

private struct CommandRow: View {
    let command: String
    let detail: String
    @State private var copied = false

    var body: some View {
        LabeledContent {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 14)
            }
            .buttonStyle(.borderless)
            .help("Copy")
        } label: {
            Text(command).font(.system(.body, design: .monospaced))
            Text(detail)
        }
    }
}

// MARK: - About

struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
            Text("Maben Awake")
                .font(.system(size: 20, weight: .semibold))
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Keeps your Mac awake for the apps your AI needs,\nand freezes everything else.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            HStack {
                Button("Show Event Log") { Integration.open(EventLog.url) }
            }
            .padding(.top, 6)
            Text(Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? "")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(width: paneWidth)
    }
}
