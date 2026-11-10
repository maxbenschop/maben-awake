import Foundation

/// The lid-open failsafe: a root launch daemon (Sources/MabenAwakeFailsafe)
/// that unfreezes apps and turns the screen back on when the lid opens, even if
/// Maben Awake itself is stuck. Installed with one password prompt by
/// `install-failsafe.sh`, which copies the binary to a root-owned location.
enum Failsafe {
    static let label = "gg.maben.awake.failsafe"
    static let installedBinary = "/Library/PrivilegedHelperTools/\(label)"
    static let daemonPlist = "/Library/LaunchDaemons/\(label).plist"

    /// The copy shipped inside the app.
    static var bundledBinary: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/maben-awake-failsafe").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static var installScript: String? { Bundle.main.path(forResource: "install-failsafe", ofType: "sh") }

    /// Installed, and the same version as the bundled copy.
    static var isUpToDate: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: daemonPlist), fm.isExecutableFile(atPath: installedBinary) else { return false }
        guard let bundled = bundledBinary else { return true }
        return version(of: installedBinary) == (bundledVersion ?? version(of: bundled))
    }

    /// Computed once: the bundled binary doesn't change while we run.
    static let bundledVersion: String? = bundledBinary.flatMap(version(of:))

    static func version(of binary: String) -> String? {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["--version"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 ? text : nil
    }

    /// Shell command that installs or updates the daemon (run as root).
    static var installCommand: String? {
        guard let script = installScript, let binary = bundledBinary else { return nil }
        return "\(shellQuote(script)) \(shellQuote(binary))"
    }

    /// Asks for the admin password and installs the daemon. Runs `osascript` as
    /// a separate process so the password dialog never blocks Maben Awake's
    /// main thread (which has to keep watching the lid).
    static func install(completion: @escaping @Sendable (Bool) -> Void) {
        guard let cmd = installCommand else { completion(false); return }
        let source = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" "
            + "with prompt \"Maben Awake wants to install its lid-open failsafe, which turns the screen back on and unfreezes apps if Maben Awake ever gets stuck.\" "
            + "with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in completion(proc.terminationStatus == 0 && isUpToDate) }
        do { try p.run() } catch { completion(false) }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
