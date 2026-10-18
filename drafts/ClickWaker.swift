import AppKit
import ApplicationServices

/// Wakes a frozen app when the user clicks it.
///
/// A SIGSTOPped app can't process activation, so NSWorkspace never reports it
/// coming to the front. Instead we watch mouse-downs globally and work out
/// which app was clicked without talking to that (frozen) app:
/// - a window: its owner from the window server list (no permission needed)
/// - a Dock icon: the icon title via Accessibility on the Dock (needs permission)
@MainActor
final class ClickWaker {
    /// Called with the pid of the clicked app, or with nil + a name for Dock icons.
    private let onClick: (_ pid: pid_t?, _ dockTitle: String?) -> Void
    private var monitor: Any?

    init(onClick: @escaping (_ pid: pid_t?, _ dockTitle: String?) -> Void) {
        self.onClick = onClick
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.handleClick(at: point) }
        }
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func handleClick(at cocoaPoint: NSPoint) {
        // Window server coordinates have their origin at the top-left of the main screen.
        let height = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: cocoaPoint.x, y: height - cocoaPoint.y)

        guard let owner = Self.windowOwner(at: point) else { return }
        if owner.name == "Dock" {
            if let title = Self.dockItemTitle(at: point, dockPID: owner.pid) { onClick(nil, title) }
        } else {
            onClick(owner.pid, nil)
        }
    }

    /// Topmost on-screen window under `point`, read from the window server.
    private static func windowOwner(at point: CGPoint) -> (pid: pid_t, name: String)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for info in list {
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point),
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { continue }
            return (pid, info[kCGWindowOwnerName as String] as? String ?? "")
        }
        return nil
    }

    /// Title of the Dock icon under `point` (the Dock itself is never frozen).
    private static func dockItemTitle(at point: CGPoint, dockPID: pid_t) -> String? {
        guard hasAccessibility else { return nil }
        let dock = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dock, 0.3)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        return title as? String
    }
}
