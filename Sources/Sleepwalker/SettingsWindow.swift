import AppKit
import SwiftUI

/// Classic preferences window with toolbar tabs. Managed by hand instead of a
/// SwiftUI `Settings` scene so it reliably comes to the front from a menu bar
/// (LSUIElement) app on every supported macOS version.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController(model: .shared)

    init(model: Model) {
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: AnyView(pane.view.environmentObject(model)))
            host.sizingOptions = []
            host.title = pane.title   // NSTabViewController titles the window with it
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        tabs.fitWindow()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        if window?.isVisible != true { window?.center() }
        // A menu bar app has no Dock icon; show one while Settings is open so
        // it can be found with ⌘-Tab.
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Fits the window to the selected pane.
private final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindow()
    }

    func fitWindow() {
        guard selectedTabViewItemIndex >= 0,
              let host = tabViewItems[selectedTabViewItemIndex].viewController as? NSHostingController<AnyView>,
              let window = view.window else { return }
        let size = host.sizeThatFits(in: NSSize(width: 520, height: 10_000))
        guard size.width > 0, size.height > 0 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}
