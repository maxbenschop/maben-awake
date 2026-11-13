import AppKit
import IOKit

/// Calls back the moment the lid opens or closes, or the screen locks or
/// unlocks, instead of on the next 3-second check: so the screen comes back
/// and apps thaw right away, and "Lock the screen when you open the lid"
/// locks before anyone can use the Mac.
@MainActor
final class Watchers {
    private let onChange: @MainActor () -> Void
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var observers: [NSObjectProtocol] = []

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        watchPowerManagement()
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange() }
            })
        }
    }

    /// IOPMrootDomain sends an interest message when the clamshell state
    /// changes (and on sleep, wake and power changes, which are all reasons to
    /// look again too).
    private func watchPowerManagement() {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        defer { IOObjectRelease(root) }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, _, _ in
            guard let context else { return }
            let watchers = Unmanaged<Watchers>.fromOpaque(context).takeUnretainedValue()
            // Runs on the main queue (set above); let IOKit finish first.
            DispatchQueue.main.async { MainActor.assumeIsolated { watchers.onChange() } }
        }, context, &notifier)
    }
}

/// Whether any of Maben Awake's windows (the menu or Settings) is on screen.
/// While none is, the app list doesn't need refreshing every 3 seconds.
@MainActor
enum UIVisibility {
    static var anyWindowVisible: Bool {
        NSApp.windows.contains { window in
            // The menu bar icon lives in a window of its own that is always visible.
            window.isVisible && window.occlusionState.contains(.visible)
                && !NSStringFromClass(type(of: window)).contains("StatusBar")
                && window.frame.width > 40 && window.frame.height > 40
        }
    }
}
