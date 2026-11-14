import SwiftUI

/// The window that drops down from the menu bar icon.
struct MenuView: View {
    @EnvironmentObject private var model: Model
    var openSettings: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Header()
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            QuickToggles()
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            Notices()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.leases.isEmpty { AIRequests() }
                    AppList()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ListHeightKey.self, value: geo.size.height)
                })
            }
            // A ScrollView has no ideal height in a MenuBarExtra window and
            // collapses to zero, so give it the height of what's in it: the
            // list only scrolls once it's taller than the maximum.
            .frame(height: listHeight)
            .onPreferenceChange(ListHeightKey.self) { measured = $0 }

            Divider()

            Footer(openSettings: openSettings)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        // Same Maben look as Settings and the website: dark, with Awake green as the accent.
        .background(MB.bg.opacity(0.92))
        .environment(\.colorScheme, .dark)
        .tint(MB.green)
        .background(GeometryReader { geo in WindowFitter(height: geo.size.height) })
        .background(WindowVisibility(visible: $visible))
        .environment(\.windowOnScreen, visible)
    }

    /// The menu window stays alive while it's closed; SwiftUI keeps updating it.
    /// Only tick the countdowns while it's on screen.
    @State private var visible = false

    /// Height of the list's content, measured; 0 until it has been laid out.
    @State private var measured: CGFloat = 0

    private var listHeight: CGFloat {
        // Before the first measurement: a close estimate, so the window doesn't open empty.
        let estimate = (model.leases.isEmpty ? 0 : 38 + CGFloat(model.leases.count) * 30)
            + 24 + CGFloat(max(model.apps.count, 1)) * 30 + 24
        return min((measured > 0 ? measured : estimate).rounded(.up), Self.maxListHeight)
    }

    /// Taller than this, the list scrolls.
    static let maxListHeight: CGFloat = 400
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// MenuBarExtra grows its window when the content gets taller but never
/// shrinks it again, leaving the content floating in empty bands. Keep the
/// window exactly as tall as the content, pinned to its top edge.
private struct WindowFitter: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { fit(view.window) }
    }

    private func fit(_ window: NSWindow?) {
        guard let window, height > 0 else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        guard abs(content.height - height) > 0.5 else { return }
        var frame = window.frame
        let delta = height - content.height
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true)
    }
}

/// Reports whether the window it's in is on screen.
struct WindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> Watcher {
        let view = Watcher()
        view.onChange = { visible = $0 }
        return view
    }

    func updateNSView(_ view: Watcher, context: Context) { view.onChange = { visible = $0 } }

    final class Watcher: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated { self?.report(closing: note.name == NSWindow.willCloseNotification) }
                })
            }
            report(closing: false)
        }

        private func report(closing: Bool) {
            guard let window else { return }
            let shown = !closing && window.isVisible && window.occlusionState.contains(.visible)
            DispatchQueue.main.async { self.onChange(shown) }
        }
    }
}

private struct WindowOnScreenKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// False while the window (the menu or Settings) is closed.
    var windowOnScreen: Bool {
        get { self[WindowOnScreenKey.self] }
        set { self[WindowOnScreenKey.self] = newValue }
    }
}

// MARK: - Header

private struct Header: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        HStack(spacing: 11) {
            StateBadge(state: model.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.headline)
                    .font(.system(size: 13, weight: .semibold))
                Text(model.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Toggle("Keep awake", isOn: $model.keepAwake)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help(model.keepAwake
                      ? "Keeping the Mac awake manually. Turn off to only stay awake for AI requests."
                      : "Keep the Mac awake manually, even without AI requests.")
        }
    }
}

/// Round badge with the menu bar moon, tinted by state.
struct StateBadge: View {
    let state: KeepAwakeState
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().fill(tint.gradient)
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(state == .awake || state == .aiWorking ? Color.black : Color.white)
        }
        .frame(width: size, height: size)
        .shadow(color: tint.opacity(0.35), radius: 3, y: 1)
        .animation(.easeInOut(duration: 0.2), value: state)
    }

    private var symbol: String {
        switch state {
        case .idle: "moon.zzz.fill"
        case .awake: "sun.max.fill"
        case .aiWorking: "sparkles"
        case .overheated: "thermometer.high"
        }
    }

    private var tint: Color {
        switch state {
        case .idle: Color(nsColor: .systemGray)
        case .awake: MB.green
        case .aiWorking: MB.green
        case .overheated: .red
        }
    }
}

// MARK: - Quick toggles

private struct QuickToggles: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        HStack(spacing: 8) {
            Tile(title: "Freeze apps", symbol: "maben.freeze", isOn: model.pauseOthers,
                 help: "While the lid is closed, freeze apps no AI needs right now.") {
                model.pauseOthers.toggle()
            }
            Tile(title: "Dim screen", symbol: "sun.min.fill", isOn: model.dimWhenClosed && Brightness.isAvailable,
                 help: Brightness.isAvailable
                    ? "Turn brightness to 0 while the lid is closed; restored when it opens."
                    : "Brightness control isn't available on this Mac.") {
                model.dimWhenClosed.toggle()
            }
            .disabled(!Brightness.isAvailable)
            if model.lidHelperInstalled {
                Tile(title: "Lid closed", symbol: "laptopcomputer", isOn: model.lidClosedMode,
                     help: "Stay awake with the lid closed while Maben Awake keeps the Mac awake. Turns off below \(model.batteryCutoff)% battery.") {
                    model.lidClosedMode.toggle()
                }
            } else {
                Tile(title: "Lid closed…", symbol: "laptopcomputer", isOn: false,
                     help: "Set up staying awake with the lid closed. Asks for your password once.") {
                    model.installLidHelper()
                }
            }
        }
    }
}

private struct Tile: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(isOn ? AnyShapeStyle(MB.green.gradient) : AnyShapeStyle(.quaternary))
                    Group {
                        if symbol == "maben.freeze" {
                            FreezeGlyph(size: 15, lineWidth: 2.1)
                        } else {
                            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .foregroundStyle(isOn ? Color.black : Color.primary.opacity(0.75))
                }
                .frame(width: 28, height: 28)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isOn ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(hovering && isEnabled ? 0.08 : 0.045))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - Notices

private struct Notices: View {
    @EnvironmentObject private var model: Model
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(spacing: 6) {
            if let release = updater.available {
                UpdateNotice(release: release)
            }
            if model.overheated {
                Notice(symbol: "thermometer.high", tint: .red,
                       text: "Too hot with the lid closed. Sleep is allowed until you open it.")
            }
            if model.recoveredFromCrash {
                Notice(symbol: "arrow.counterclockwise.circle.fill", tint: .orange,
                       text: "Recovered from a crash. Frozen apps were thawed.",
                       dismiss: { model.dismissCrashNotice() })
            }
            if let summary = model.awaySummary {
                Notice(symbol: summary.stoppedBecause == nil ? "moon.stars.fill" : "exclamationmark.triangle.fill",
                       tint: summary.stoppedBecause == nil ? MB.green : .orange,
                       text: summary.text
                           + (summary.stoppedBecause.map { ". Stopped early: \($0)." } ?? "."),
                       dismiss: { model.dismissAwaySummary() })
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, model.overheated || model.recoveredFromCrash || updater.available != nil
                 || model.awaySummary != nil ? 12 : 0)
    }
}

/// "Maben Awake 1.5 is available" with an Update button, at the top of the menu.
private struct UpdateNotice: View {
    @ObservedObject private var updater = Updater.shared
    let release: Updater.Release

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(MB.green).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 1) {
                Text("Version \(release.version) is available").font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if case .available = updater.state {
                Button("Update") { updater.install() }
                    .buttonStyle(.mbPrimary)
                    .disabled(!updater.canInstall)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(MB.green.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(MB.green.opacity(0.3)))
    }

    private var detail: String {
        switch updater.state {
        case .downloading(_, let p): "Downloading… \(Int(p * 100))%"
        case .installing: "Installing, restarts in a moment"
        default: updater.canInstall ? "Installs in a few seconds and restarts" : "Move the app to Applications to update"
        }
    }
}

private struct Notice: View {
    let symbol: String
    let tint: Color
    let text: String
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.12)))
    }
}

// MARK: - AI requests

private struct AIRequests: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "AI Requests") {
                Button("Release All") { model.releaseAllLeases() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            // Countdowns tick even when nothing else changes, but only while the
            // menu is open: a closed menu redrawing every second costs CPU all day.
            if visible {
                TimelineView(.periodic(from: .now, by: 1)) { _ in rows }
            } else {
                rows
            }
        }
    }

    @Environment(\.windowOnScreen) private var visible

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(model.leases) { lease in LeaseRow(lease: lease) }
        }
    }
}

private struct LeaseRow: View {
    @EnvironmentObject private var model: Model
    let lease: Lease
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: lease.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MB.text)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.08)))
            Text(lease.title)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .help(lease.name)
            Spacer(minLength: 6)
            Text(lease.detail)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Button { model.release(lease) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0.55)
            .help("Release this request")
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .onHover { hovering = $0 }
    }
}

// MARK: - Apps

private struct AppList: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Apps") {
                if model.frozenCount > 0 {
                    Label { Text("\(model.frozenCount) frozen") } icon: { FreezeGlyph(size: 11) }
                        .font(.system(size: 11))
                        .foregroundStyle(MB.cold)
                }
            }
            VStack(spacing: 2) {
                ForEach(model.apps) { app in AppRow(app: app) }
            }
            if model.apps.isEmpty {
                Text("No apps running")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
        }
    }
}

private struct AppRow: View {
    @EnvironmentObject private var model: Model
    let app: AppEntry
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            AppIcon(image: app.icon, size: 22)
                .saturation(app.isPaused ? 0.2 : 1)
                .opacity(app.isPaused ? 0.6 : 1)
            Text(app.name)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .foregroundStyle(app.isPaused ? .secondary : .primary)
            if app.isPaused {
                FreezeGlyph(size: 11, lineWidth: 2.2)
                    .foregroundStyle(MB.cold)
                    .help("Frozen by Maben Awake while the lid is closed")
            }
            Spacer(minLength: 6)
            ModeMenu(bundleID: app.bundleID)
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .onHover { hovering = $0 }
    }
}

/// Compact pop-up for an app's mode, shared by the menu and Settings.
struct ModeMenu: View {
    @EnvironmentObject private var model: Model
    let bundleID: String

    var body: some View {
        let mode = model.mode(of: bundleID)
        let protected = model.isProtectedByDefault(bundleID)
        Menu {
            Picker("Mode", selection: Binding(
                get: { model.mode(of: bundleID) },
                set: { model.setMode(bundleID: bundleID, $0) }
            )) {
                ForEach(AppMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Text(mode.explanation.replacingOccurrences(of: "`", with: ""))
            if protected {
                Text("Protected by default (calls, audio, passwords, terminals…)")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: protected && mode == .always ? "shield.lefthalf.filled" : mode.symbol)
                Text(mode.shortLabel)
            }
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .tint(MB.text)
        .fixedSize()
        .help("\(mode.label): \(mode.explanation.replacingOccurrences(of: "`", with: ""))")
    }
}

struct AppIcon: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.tertiary)
                .frame(width: size, height: size)
        }
    }
}

private struct SectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            accessory
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
    }
}

// MARK: - Footer

private struct Footer: View {
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            FooterButton(title: "Settings…", symbol: "gearshape", action: openSettings)
                .keyboardShortcut(",", modifiers: .command)
            Spacer()
            FooterButton(title: "Quit Maben Awake", symbol: "power") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
                .help("Quit. Frozen apps are thawed and normal sleep is restored.")
        }
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Lease presentation

extension Lease {
    var title: String {
        if let app { return "Using \(app == "browser" ? "the browser" : app)" }
        if name.hasSuffix("-wakeup") { return "Scheduled check" }
        if name.hasSuffix("-cron") { return "Recurring task" }
        if name.hasSuffix("-bg") { return "Background task" }
        if name.hasSuffix("-monitor") { return "Watching a task" }
        if let agent = Integration.agentName(ofLease: name) { return "\(agent) is working" }
        return name
    }

    var symbol: String {
        if app != nil { return "macwindow" }
        if name.hasSuffix("-wakeup") { return "alarm" }
        if name.hasSuffix("-cron") { return "repeat" }
        if name.hasSuffix("-bg") || name.hasSuffix("-monitor") { return "gearshape.2" }
        if Integration.agentName(ofLease: name) != nil { return "sparkles" }
        return "cup.and.saucer.fill"
    }

    /// Turn holds show "now"; their expiry is only a safety cap. Others count down.
    var detail: String {
        if isWork && Integration.agentName(ofLease: name) != nil { return "now" }
        if name.hasSuffix("-wakeup") { return "in " + Self.format(remaining - 300) }
        return Self.format(remaining) + " left"
    }

    private static func format(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }
}
