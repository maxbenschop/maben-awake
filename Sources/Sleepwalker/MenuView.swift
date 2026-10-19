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
            }
            // A ScrollView has no ideal height in a MenuBarExtra window and
            // collapses to zero, so size it to its content explicitly.
            .frame(height: listHeight)

            Divider()

            Footer(openSettings: openSettings)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geo in WindowFitter(height: geo.size.height) })
    }

    private var listHeight: CGFloat {
        let leases = model.leases.isEmpty ? 0 : 26 + CGFloat(model.leases.count) * 30
        let apps = 26 + CGFloat(max(model.apps.count, 1)) * 30
        return min(leases + apps + 24, 400)
    }
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
                .foregroundStyle(.white)
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
        case .awake: .indigo
        case .aiWorking: .purple
        case .overheated: .red
        }
    }
}

// MARK: - Quick toggles

private struct QuickToggles: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        HStack(spacing: 8) {
            Tile(title: "Freeze apps", symbol: "snowflake", isOn: model.pauseOthers,
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
                     help: "Stay awake with the lid closed while Sleepwalker keeps the Mac awake. Turns off below \(model.batteryCutoff)% battery.") {
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
                        .fill(isOn ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.quaternary))
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.75))
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

    var body: some View {
        VStack(spacing: 6) {
            if model.overheated {
                Notice(symbol: "thermometer.high", tint: .red,
                       text: "Too hot with the lid closed. Sleep is allowed until you open it.")
            }
            if model.recoveredFromCrash {
                Notice(symbol: "arrow.counterclockwise.circle.fill", tint: .orange,
                       text: "Recovered from a crash. Frozen apps were thawed.",
                       dismiss: { model.dismissCrashNotice() })
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, model.overheated || model.recoveredFromCrash ? 12 : 0)
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
            // Countdowns tick even when nothing else changes.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(spacing: 2) {
                    ForEach(model.leases) { lease in LeaseRow(lease: lease) }
                }
            }
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
                .foregroundStyle(.purple)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.purple.opacity(0.14)))
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
                    Label("\(model.frozenCount) frozen", systemImage: "snowflake")
                        .font(.system(size: 11))
                        .foregroundStyle(.cyan)
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
                Image(systemName: "snowflake")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .help("Frozen by Sleepwalker while the lid is closed")
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
            FooterButton(title: "Quit Sleepwalker", symbol: "power") { NSApp.terminate(nil) }
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
        if name.hasPrefix("claude-") { return "Claude is working" }
        return name
    }

    var symbol: String {
        if app != nil { return "macwindow" }
        if name.hasSuffix("-wakeup") { return "alarm" }
        if name.hasSuffix("-cron") { return "repeat" }
        if name.hasSuffix("-bg") || name.hasSuffix("-monitor") { return "gearshape.2" }
        if name.hasPrefix("claude-") { return "sparkles" }
        return "cup.and.saucer.fill"
    }

    /// Turn holds show "now"; their expiry is only a safety cap. Others count down.
    var detail: String {
        if isWork && name.hasPrefix("claude-") { return "now" }
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
