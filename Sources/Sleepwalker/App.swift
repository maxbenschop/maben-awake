import SwiftUI

@main
struct SleepwalkerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: Model

    init() {
        Instance.ensureSingle()   // may exit: another instance / the launchd agent takes over
        _model = StateObject(wrappedValue: Model.shared)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
        } label: {
            Image(nsImage: MenuIcon.image(
                model.overheated ? .overheated
                    : !model.isAsserting ? .idle
                    : model.aiWorking ? .aiWorking : .awake))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Model.shared.shutdown() }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Keep Mac awake", isOn: $model.keepAwake)
                .toggleStyle(.switch)
                .font(.headline)

            Group {
                Toggle("Only while an \"Always on\" app is running", isOn: $model.onlyWhileCheckedRunning)
                Toggle("Freeze unneeded apps while lid is closed", isOn: $model.pauseOthers)
                Toggle("Screen brightness to 0 while lid is closed", isOn: $model.dimWhenClosed)
                    .disabled(!Brightness.isAvailable)
            }
            .toggleStyle(.checkbox)
            .disabled(!model.keepAwake)

            if model.lidHelperInstalled {
                Toggle("Stay awake with lid closed", isOn: $model.lidClosedMode)
                    .toggleStyle(.checkbox)
                    .help("Turns off below 10% battery.")
            } else {
                Button("Enable lid-closed mode…") { model.installLidHelper() }
                    .controlSize(.small)
                    .help("Asks for your password once.")
            }

            if model.recoveredFromCrash {
                Label("Recovered from a crash: frozen apps were thawed", systemImage: "arrow.counterclockwise.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.overheated {
                Label("Too hot with the lid closed: let the Mac sleep to cool down", systemImage: "thermometer.high")
                    .font(.caption).foregroundStyle(.red)
            }

            if !model.leases.isEmpty {
                Divider()
                HStack {
                    Text("AI requests")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Release all") { model.releaseAllLeases() }
                        .controlSize(.mini)
                }
                ForEach(model.leases) { lease in
                    HStack(spacing: 6) {
                        Image(systemName: lease.app != nil ? "app.badge.checkmark" : "sparkles")
                            .foregroundStyle(.purple)
                        Text(leaseTitle(lease)).lineLimit(1)
                        Spacer()
                        Text(leaseDetail(lease))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button { model.release(lease) } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Release this request")
                    }
                }
            }

            Divider()

            Text("Apps")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.apps) { app in
                        AppRow(app: app).frame(height: 20)
                    }
                    if model.apps.isEmpty {
                        Text("No apps running").foregroundStyle(.secondary)
                    }
                }
            }
            // ScrollView has no ideal height in a MenuBarExtra window and collapses
            // to zero, so size it to its rows explicitly.
            .frame(height: min(CGFloat(max(model.apps.count, 1)) * 24, 320))

            Divider()

            Toggle("Start at login and restart after crashes", isOn: $model.launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)

            HStack {
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private func leaseTitle(_ lease: Lease) -> String {
        if let app = lease.app { return "Using \(app == "browser" ? "browser" : app)" }
        if lease.name.hasSuffix("-wakeup") { return "Scheduled check" }
        if lease.name.hasSuffix("-cron") { return "Recurring task" }
        if lease.name.hasSuffix("-bg") { return "Background task" }
        if lease.name.hasSuffix("-monitor") { return "Watching task" }
        if lease.name.hasPrefix("claude-") { return "Claude working" }
        return lease.name
    }

    /// Turn holds show "now"; their expiry is only a safety cap. Others count down.
    private func leaseDetail(_ lease: Lease) -> String {
        if lease.isWork && lease.name.hasPrefix("claude-") { return "now" }
        if lease.name.hasSuffix("-wakeup") { return "next in " + remaining(lease.remaining - 300) }
        return remaining(lease.remaining)
    }

    private func remaining(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }
}

private struct AppRow: View {
    @EnvironmentObject private var model: Model
    let app: AppEntry

    var body: some View {
        HStack(spacing: 8) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }
            Text(app.name).lineLimit(1)
            Spacer()
            if app.isPaused {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.orange)
                    .help("Frozen by Sleepwalker while the lid is closed.")
            }
            if model.isProtectedByDefault(app.bundleID) && model.mode(of: app.bundleID) == .always {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(.secondary)
                    .help("Never frozen by default (calls, audio, passwords, VPN, terminals and editors…)")
            }
            Picker("", selection: Binding(
                get: { model.mode(of: app.bundleID) },
                set: { model.setMode(app, $0) }
            )) {
                ForEach(AppMode.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
    }
}
