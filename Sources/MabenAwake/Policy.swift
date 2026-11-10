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
        "com.sublimetext.4", "com.panic.nova", "com.google.android.studio", "org.tabby",
        "com.apple.iphonesimulator",
        // Calls and chat (calls, huddles, and staying reachable)
        "us.zoom.xos", "com.apple.facetime", "com.microsoft.teams2", "com.microsoft.teams",
        "com.hnc.discord", "com.cisco.webexmeetingsapp", "com.google.meet",
        "com.tinyspeck.slackmacgap", "net.whatsapp.whatsapp", "ru.keepcoder.telegram",
        "org.telegram.desktop", "org.whispersystems.signal-desktop",
        // Audio
        "com.apple.music", "com.spotify.client", "com.apple.podcasts", "com.apple.audible",
        // Passwords
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.passwords", "com.lastpass.lastpassmacdesktop", "org.keepassxc.keepassxc",
        // VPN / network
        "io.tailscale.ipn.macos", "com.tailscale.ipn.macos", "com.wireguard.macos", "com.nordvpn.macos",
        "com.expressvpn.expressvpn", "ch.protonvpn.mac", "com.cloudflare.1dot1dot1dot1.macos",
        "net.mullvad.vpn",
        // Remote access: someone may be using this Mac from elsewhere
        "com.teamviewer.teamviewer", "com.philandro.anydesk", "tv.parsec.www", "com.carriez.rustdesk",
        // Sync / backup
        "com.getdropbox.dropbox", "com.google.drivefs", "com.microsoft.onedrive",
        "com.backblaze.bzbmenu", "com.apple.cloudphotod",
        // Containers and local models the AI may call
        "com.docker.docker", "com.electron.dockerdesktop", "dev.kdrag0n.macvirt", "com.electron.ollama", "ai.elementlabs.lmstudio",
        "io.podman_desktop.podmandesktop", "io.rancherdesktop.app",
        // Virtual machines
        "com.utmapp.utm", "com.parallels.desktop.console", "com.vmware.fusion", "org.virtualbox.app.virtualbox",
        // Long jobs people leave running with the lid closed: exports, renders, downloads
        "com.apple.finalcut", "com.apple.compressor", "com.apple.logic10", "fr.handbrake.handbrake",
        "com.blackmagic-design.davinciresolve", "org.blenderfoundation.blender", "com.obsproject.obs-studio",
        "com.valvesoftware.steam", "com.apple.appstore", "org.m0k.transmission", "org.qbittorrent.qbittorrent",
        // Messaging and system
        "com.apple.mobilesms", "com.apple.mail", "com.apple.activitymonitor", "com.apple.systempreferences",
    ]

    /// Vendors whose apps are all protected (e.g. every JetBrains IDE).
    private static let neverFreezePrefixes = ["com.jetbrains."]

    static func isProtectedByDefault(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return neverFreeze.contains(id) || neverFreezePrefixes.contains { id.hasPrefix($0) }
    }

    /// Folders installed apps live in. Anything else (DerivedData, `.build`,
    /// /tmp, a project's build/ folder) is treated as an app under development.
    private static let installedRoots = ["/Applications/", "/System/", "/Library/",
                                         NSHomeDirectory() + "/Applications/"]

    static func isDevBuild(_ bundleURL: URL?) -> Bool {
        guard let path = bundleURL?.resolvingSymlinksInPath().path else { return false }
        // Downloaded apps run from a quarantine copy until moved to /Applications.
        if path.contains("/AppTranslocation/") { return false }
        return !installedRoots.contains { path.hasPrefix($0) }
    }
}
