import SwiftUI

@main
struct SleepwalkerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: Model

    init() {
        #if DEBUG
        Snapshot.runIfRequested()   // exits; never starts the real app
        #endif
        Instance.ensureSingle()   // may exit: another instance / the launchd agent takes over
        _model = StateObject(wrappedValue: Model.shared)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(openSettings: { SettingsWindowController.shared.show() })
                .environmentObject(model)
        } label: {
            Image(nsImage: MenuIcon.image(model.state.icon))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
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
