#if DEBUG
import AppKit
import SwiftUI

/// `MabenAwake --snapshot <dir>` (debug builds only) renders the menu and
/// every Settings pane to PNGs with canned data, without touching apps,
/// power settings or a running Maben Awake.
@MainActor
enum Snapshot {
    /// `MabenAwake --preview-settings` (debug builds): opens only the Settings
    /// window with canned data, to try it out next to the installed app. Nothing
    /// is frozen and no real settings are changed.
    static func previewSettingsIfRequested() {
        guard CommandLine.arguments.contains("--preview-settings") else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        func icon(_ id: String) -> NSImage? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        let apps: [(String, String, Bool)] = [
            ("Dia", "company.thebrowser.dia", false), ("Docker", "com.docker.docker", false),
            ("Figma", "com.figma.desktop", true), ("Mail", "com.apple.mail", false),
            ("Notes", "com.apple.Notes", true), ("Spotify", "com.spotify.client", false),
            ("Terminal", "com.apple.Terminal", false), ("Xcode", "com.apple.dt.Xcode", false),
        ]
        let entries = apps.enumerated().map { n, a in
            AppEntry(id: pid_t(100 + n), bundleID: a.1, name: a.0, icon: icon(a.1), isPaused: a.2)
        }
        let now = Date()
        let leases = [Lease(name: "claude-3f2a", expires: now + 540, app: nil, owner: 0),
                      Lease(name: "need-Dia-4411", expires: now + 425, app: "Dia", owner: 0)]
        let model = Model(preview: entries, leases: leases, asserting: true, away: true,
                          modes: ["com.docker.docker": .always, "com.figma.desktop": .whileAI])
        let controller = SettingsWindowController(model: model)
        controller.window?.title = "Maben Awake Settings (preview)"
        controller.window?.setFrameAutosaveName("")
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(nil)
        app.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: controller.window, queue: .main) { _ in exit(0) }
        withExtendedLifetime(controller) { app.run() }
        exit(0)
    }

    /// `MabenAwake --verify-update <app> <version>` (debug): runs the updater's checks on an app and prints the result.
    static func verifyUpdateIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--verify-update"), i + 2 < args.count else { return }
        do {
            try Updater.verify(URL(fileURLWithPath: args[i + 1]), expectedVersion: args[i + 2])
            print("ACCEPTED")
        } catch {
            print("REJECTED: \((error as? Updater.Failure)?.message ?? "\(error)")")
        }
        let sample = #"{"tag_name":"v1.4.1","draft":false,"prerelease":false,"html_url":"https://github.com/x/y/releases/tag/v1.4.1","body":"- Fix","assets":[{"name":"Maben-Awake.dmg","browser_download_url":"https://e/a.dmg"},{"name":"Maben-Awake.zip","browser_download_url":"https://e/a.zip"}]}"#
        let r = Updater.parse(Data(sample.utf8))
        print("parse:", r?.version ?? "nil", r?.zip.absoluteString ?? "", "newer than 1.4:", Updater.isNewer(r?.version ?? "0", than: "1.4"))
        print("prerelease ignored:", Updater.parse(Data(sample.replacingOccurrences(of: #""prerelease":false"#, with: #""prerelease":true"#).utf8)) == nil)
        exit(0)
    }

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        useDemoConnections()
        // The version in Info.plist, which a debug build doesn't bundle.
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Info.plist")
        Updater.shared.versionOverride = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? "dev"
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        // A debug build has no app icon in its bundle; use the one build.sh renders.
        let iconFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../build/AppIcon.icns")
        if let image = NSImage(contentsOf: iconFile) { image.setName("AppIcon"); NSApp.applicationIconImage = image }

        func icon(_ id: String) -> NSImage? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        let apps: [(String, String, Bool)] = [
            ("Dia", "company.thebrowser.dia", false), ("Docker", "com.docker.docker", false),
            ("Figma", "com.figma.desktop", true), ("Mail", "com.apple.mail", false),
            ("Notes", "com.apple.Notes", true), ("Spotify", "com.spotify.client", false),
            ("T3 Code", "com.t3tools.t3code", false), ("Xcode", "com.apple.dt.Xcode", false),
        ]
        let entries = apps.enumerated().map { n, a in
            AppEntry(id: pid_t(100 + n), bundleID: a.1, name: a.0, icon: icon(a.1), isPaused: a.2)
        }
        let now = Date()
        let leases = [
            Lease(name: "claude-3f2a", expires: now + 540, app: nil, owner: 0),
            Lease(name: "need-Dia-4411", expires: now + 425, app: "Dia", owner: 0),
            Lease(name: "e2e", expires: now + 1500, app: nil, owner: 0),
        ]
        let modes: [String: AppMode] = ["com.docker.docker": .always, "com.figma.desktop": .whileAI,
                                        "com.apple.dt.Xcode": .always, "com.apple.mail": .onDemand]
        let back = AwaySummary(duration: 2 * 3600 + 14 * 60, keptAwake: 3600 + 50 * 60, agents: ["Claude", "Codex"],
                               otherRequests: false, mostFrozen: 4, batteryStart: 86, batteryEnd: 61, stoppedBecause: nil)
        let busy = Model(preview: entries, leases: leases, asserting: true, away: true, modes: modes)
        let returned = Model(preview: entries, leases: Array(leases.prefix(1)), asserting: true, modes: modes, awaySummary: back)
        let idle = Model(preview: Array(entries.prefix(5)), leases: [], asserting: false, modes: modes,
                         lidHelper: false, recovered: true)
        idle.keepAwake = false
        let hot = Model(preview: Array(entries.prefix(3)), leases: [], asserting: false, overheated: true)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            render(MenuView().environmentObject(busy), "menu-busy-\(suffix)", appearance, dir, menu: true)
            render(MenuView().environmentObject(idle), "menu-idle-\(suffix)", appearance, dir, menu: true)
            render(MenuView().environmentObject(hot), "menu-hot-\(suffix)", appearance, dir, menu: true)
            render(MenuView().environmentObject(returned), "menu-back-\(suffix)", appearance, dir, menu: true)
            for pane in SettingsPane.allCases {
                render(pane.view.environmentObject(busy), "settings-\(pane.rawValue)-\(suffix)", appearance, dir)
            }
            render(LidPane().environmentObject(idle), "settings-lid-nohelper-\(suffix)", appearance, dir)
        }
        // The real Settings window: every page, light and dark.
        let controller = SettingsWindowController(model: busy)
        if let window = controller.window {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                window.orderFrontRegardless()
                for pane in SettingsPane.allCases {
                    controller.navigation.pane = pane
                    RunLoop.main.run(until: Date() + 0.4)
                    if let view = window.contentView?.superview ?? window.contentView,
                       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        let suffix = appearance == .aqua ? "light" : "dark"
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: dir.appendingPathComponent("window-\(pane.rawValue)-\(suffix).png"))
                    }
                }
            }
            window.orderOut(nil)
        }
        print("Snapshots written to \(dir.path)")
        exit(0)
    }

    /// Points Settings → Agents at a scratch home folder with a typical setup
    /// (Claude Code and Codex connected, a few other agents installed), so the
    /// pictures don't depend on, or show, this Mac's own configuration.
    private static func useDemoConnections() {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("maben-awake-snapshot-home")
        try? fm.removeItem(at: home)
        Integration.home = home
        Integration.bundle = URL(fileURLWithPath: "/Applications/Maben Awake.app")
        for folder in [".claude", ".codex", ".cursor", ".gemini", ".copilot", ".local/bin"] {
            try? fm.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        _ = try? Integration.installHooks()
        try? Integration.install(Integration.agent("codex"))
        let cli = home.appendingPathComponent(".local/bin/awake").path
        Integration.cliCandidates = [cli]
        try? fm.createSymbolicLink(atPath: cli, withDestinationPath: Integration.cliTarget)
    }

    private static func render<V: View>(_ view: V, _ name: String, _ appearance: NSAppearance.Name,
                                        _ dir: URL, menu: Bool = false) {
        let host = NSHostingView(rootView: view.background(menu ? Color.clear : Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        let container: NSView
        if menu {
            let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            effect.material = .popover
            effect.state = .active
            effect.blendingMode = .behindWindow
            effect.appearance = host.appearance
            host.frame = effect.bounds
            effect.addSubview(host)
            container = effect
        } else {
            host.frame = NSRect(origin: .zero, size: size)
            container = host
        }
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date() + 0.3)
        container.layoutSubtreeIfNeeded()
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
        container.cacheDisplay(in: container.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
    }
}
#endif
