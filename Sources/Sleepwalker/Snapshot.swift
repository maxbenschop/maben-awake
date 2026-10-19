#if DEBUG
import AppKit
import SwiftUI

/// `Sleepwalker --snapshot <dir>` (debug builds only) renders the menu and
/// every Settings pane to PNGs with canned data, without touching apps,
/// power settings or a running Sleepwalker.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

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
        let busy = Model(preview: entries, leases: leases, asserting: true, away: true, modes: modes)
        let idle = Model(preview: Array(entries.prefix(5)), leases: [], asserting: false, modes: modes,
                         lidHelper: false, recovered: true)
        idle.keepAwake = false
        let hot = Model(preview: Array(entries.prefix(3)), leases: [], asserting: false, overheated: true)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            render(MenuView().environmentObject(busy), "menu-busy-\(suffix)", appearance, dir, menu: true)
            render(MenuView().environmentObject(idle), "menu-idle-\(suffix)", appearance, dir, menu: true)
            render(MenuView().environmentObject(hot), "menu-hot-\(suffix)", appearance, dir, menu: true)
            for pane in SettingsPane.allCases {
                render(pane.view.environmentObject(busy), "settings-\(pane.rawValue)-\(suffix)", appearance, dir)
            }
            render(LidPane().environmentObject(idle), "settings-lid-nohelper-\(suffix)", appearance, dir)
        }
        // The real Settings window: switch through every tab.
        let controller = SettingsWindowController(model: busy)
        if let window = controller.window, let tabs = window.contentViewController as? NSTabViewController {
            window.appearance = NSAppearance(named: .aqua)
            for (i, pane) in SettingsPane.allCases.enumerated() {
                tabs.selectedTabViewItemIndex = i
                RunLoop.main.run(until: Date() + 0.4)
                print("window \(pane.rawValue): title=\(window.title) size=\(window.frame.size)")
                if let view = window.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: dir.appendingPathComponent("window-\(pane.rawValue).png"))
                }
            }
        }
        print("Snapshots written to \(dir.path)")
        exit(0)
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
