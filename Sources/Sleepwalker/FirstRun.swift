import AppKit

/// What a new user sees the first time the app starts. A menu bar app shows
/// nothing on launch, so without this a fresh download looks like it did
/// nothing, and the hooks that make it useful would never get installed.
@MainActor
enum FirstRun {
    static func run() {
        let defaults = UserDefaults.standard
        let path = Bundle.main.bundlePath

        // Opened straight from Downloads or a disk image: macOS runs the app
        // from a temporary read-only copy, so anything that stores its path
        // (login item, hooks, the awake command) would break. Ask to move it.
        let translocated = path.contains("/AppTranslocation/")
        let inDownloads = [".Trash", "Downloads", "Desktop"].contains { path.contains("/\($0)/") }
        if translocated || inDownloads {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Move Maben Awake to Applications first"
            alert.informativeText = "Maben Awake starts at login and connects to your AI tools by its location. "
                + "Drag it to your Applications folder, then open it from there."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Continue Anyway")
            if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil); return }
            NSApp.setActivationPolicy(.accessory)
            return
        }

        // First start from Applications with no hooks yet: open Settings on
        // the AI tab, where both can be installed with a click. Someone who
        // already has the hooks (an update, or a build.sh install) sees nothing.
        guard Integration.isInApplications, !defaults.bool(forKey: "didOfferSetup") else { return }
        defaults.set(true, forKey: "didOfferSetup")
        if Integration.hooksStatus == .missing { SettingsWindowController.shared.show(.ai) }
    }
}
