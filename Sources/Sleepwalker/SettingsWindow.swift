import AppKit
import SwiftUI

/// Settings in the Maben style: a dark sidebar with the wordmark, search and the
/// pages in groups, and the page on the right, in a window of fixed size.
/// Switching pages swaps one view; nothing is measured or resized, so it's
/// instant. Only the visible page exists, so hidden pages don't redraw.
///
/// Managed by hand instead of a SwiftUI `Settings` scene so it reliably comes
/// to the front from a menu bar (LSUIElement) app on every supported macOS.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var pane: SettingsPane = .general
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController(model: .shared)
    static let size = NSSize(width: 780, height: 580)
    let navigation = SettingsNavigation()

    init(model: Model) {
        let root = SettingsRoot().environmentObject(model).environmentObject(navigation)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = host
        window.setContentSize(Self.size)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Maben Awake Settings"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // Maben is dark, like the website, whatever the system appearance.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.035, green: 0.035, blue: 0.04, alpha: 1)
        // Taller is allowed (long app lists); the width stays fixed.
        window.contentMinSize = NSSize(width: Self.size.width, height: 480)
        window.contentMaxSize = NSSize(width: Self.size.width, height: 2000)
        window.setFrameAutosaveName("MabenAwakeSettings")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Brings Settings to the front, optionally on a given page.
    func show(_ pane: SettingsPane? = nil) {
        if let pane { navigation.pane = pane }
        // First time: centre it. After that the window opens where you left it.
        if window?.isVisible != true, UserDefaults.standard.string(forKey: "NSWindow Frame MabenAwakeSettings") == nil {
            window?.center()
        }
        // A menu bar app has no Dock icon; show one while Settings is open so
        // it can be found with ⌘-Tab.
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Don't start with a blinking cursor in a text field.
        window?.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Sidebar plus the selected page.
struct SettingsRoot: View {
    @EnvironmentObject private var navigation: SettingsNavigation

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 210)
                .background(MB.sidebar)
            Rectangle().fill(MB.line).frame(width: 1)
            navigation.pane.view
                .id(navigation.pane)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(MB.bg)
        }
        .ignoresSafeArea()
        .frame(width: SettingsWindowController.size.width)
        .frame(minHeight: 480, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .tint(MB.green)
        .background(KeyboardNavigation())
    }
}

/// ⌘1–⌘5 jump to a page; ⌘↑ and ⌘↓ go to the previous or next one.
private struct KeyboardNavigation: View {
    @EnvironmentObject private var navigation: SettingsNavigation

    var body: some View {
        let panes = SettingsPane.allCases
        ZStack {
            ForEach(Array(panes.enumerated()), id: \.offset) { i, pane in
                Button("") { navigation.pane = pane }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Button("") { step(-1) }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("") { step(1) }.keyboardShortcut(.downArrow, modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func step(_ d: Int) {
        let panes = SettingsPane.allCases
        guard let i = panes.firstIndex(of: navigation.pane) else { return }
        navigation.pane = panes[(i + d + panes.count) % panes.count]
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var navigation: SettingsNavigation
    @EnvironmentObject private var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Under the window buttons, lined up with the page icons below it.
            // Its baseline lines up with the page title on the right.
            MBWordmark(size: 17)
                .padding(.leading, 10)
                .padding(.top, 38)
                .padding(.bottom, 30)
            ForEach(Array([SettingsPane.general, .apps, .lid, .ai].enumerated()), id: \.offset) { i, pane in
                SidebarRow(pane: pane, shortcut: i + 1, selected: navigation.pane == pane) { navigation.pane = pane }
            }
            Spacer()
            SidebarRow(pane: .about, shortcut: 5, selected: navigation.pane == .about) { navigation.pane = .about }
            HStack(spacing: 7) {
                Circle()
                    .fill(model.isAsserting ? MB.green : MB.dim)
                    .frame(width: 7, height: 7)
                    .shadow(color: model.isAsserting ? MB.green.opacity(0.6) : .clear, radius: 3)
                Text(model.isAsserting ? "Keeping the Mac awake" : "The Mac can sleep")
                    .font(.system(size: 11.5))
                    .foregroundStyle(MB.muted)
            }
            .padding(.leading, 10)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 12)
    }
}

private struct SidebarRow: View {
    let pane: SettingsPane
    let shortcut: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? MB.green : MB.muted)
                    .frame(width: 18)
                Text(pane.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? MB.text : MB.muted)
                Spacer(minLength: 0)
                if hovering && !selected {
                    Text("⌘\(shortcut)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(MB.dim)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? MB.green.opacity(0.13) : Color.white.opacity(hovering ? 0.05 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? MB.green.opacity(0.28) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(pane.title) (⌘\(shortcut))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
