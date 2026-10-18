import Foundation

/// Apps that are "Always on" unless the user picks another mode for them:
/// freezing them would break calls, audio, logins, network or the AI itself.
enum Policy {
    private static let neverFreeze: Set<String> = [
        // Where AI agents run: terminals, editors, AI apps
        "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
        "com.microsoft.vscode", "com.microsoft.vscodeinsiders", "com.todesktop.230313mxl7n",
        "com.exafunction.windsurf", "dev.zed.zed", "dev.zed.zed-preview", "com.apple.dt.xcode",
        "com.t3tools.t3code", "com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex",
        // Calls
        "us.zoom.xos", "com.apple.facetime", "com.microsoft.teams2", "com.microsoft.teams",
        "com.hnc.discord", "com.cisco.webexmeetingsapp", "com.google.meet",
        // Audio
        "com.apple.music", "com.spotify.client", "com.apple.podcasts", "com.apple.audible",
        // Passwords
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.passwords", "com.lastpass.lastpassmacdesktop",
        // VPN / network
        "io.tailscale.ipn.macos", "com.tailscale.ipn.macos", "com.wireguard.macos", "com.nordvpn.macos",
        "com.expressvpn.expressvpn", "ch.protonvpn.mac", "com.cloudflare.1dot1dot1dot1.macos",
        "net.mullvad.vpn",
        // Sync / backup
        "com.getdropbox.dropbox", "com.google.drivefs", "com.microsoft.onedrive",
        "com.backblaze.bzbmenu", "com.apple.cloudphotod",
        // Containers and local models the AI may call
        "com.docker.docker", "com.electron.dockerdesktop", "dev.kdrag0n.macvirt", "com.electron.ollama", "ai.elementlabs.lmstudio",
        // Messaging and system
        "com.apple.mobilesms", "com.apple.mail", "com.apple.activitymonitor", "com.apple.systempreferences",
    ]

    /// Vendors whose apps are all protected (e.g. every JetBrains IDE).
    private static let neverFreezePrefixes = ["com.jetbrains."]

    static func isProtectedByDefault(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return neverFreeze.contains(id) || neverFreezePrefixes.contains { id.hasPrefix($0) }
    }
}
