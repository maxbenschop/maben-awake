import SwiftUI

@main
struct SleepwalkerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: Model
    @ObservedObject private var updater = Updater.shared

    init() {
        #if DEBUG
        Snapshot.runIfRequested()   // exits; never starts the real app
        Snapshot.verifyUpdateIfRequested()   // exits
        Snapshot.previewSettingsIfRequested()   // exits when the preview window closes
        #endif
        Instance.ensureSingle()   // may exit: another instance / the launchd agent takes over
        _model = StateObject(wrappedValue: Model.shared)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(openSettings: { SettingsWindowController.shared.show() })
                .environmentObject(model)
        } label: {
            // Green while an update is waiting to be installed.
            Image(nsImage: MenuIcon.image(model.state.icon, tint: updater.available == nil ? nil : MenuIcon.updateTint))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            FirstRun.run()
            Updater.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Model.shared.shutdown() }
    }
}

extension KeepAwakeState {
    var icon: MenuIcon.State {
        switch self {
        case .idle: .idle
        case .awake: .awake
        case .aiWorking: .aiWorking
        case .overheated: .overheated
        }
    }
}
