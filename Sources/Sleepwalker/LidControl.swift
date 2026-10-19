import AppKit
import IOKit.ps

/// Closed-lid sleep control.
///
/// macOS ignores power assertions when the lid closes on battery; only
/// `pmset disablesleep 1` (root) stops that. A one-time sudoers rule installed by
/// `install-lid-helper.sh` lets us run exactly that command without a password.
enum LidControl {
    /// Current rule file, plus the one installed under the app's old name.
    static let sudoersFiles = ["/etc/sudoers.d/sleepwalker", "/etc/sudoers.d/awakekeeper"]

    static var isHelperInstalled: Bool { sudoersFiles.contains { FileManager.default.fileExists(atPath: $0) } }

    /// Asks for the admin password once and installs the sudoers rule.
    @discardableResult
    static func installHelper() -> Bool {
        guard let script = Bundle.main.path(forResource: "install-lid-helper", ofType: "sh") else { return false }
        let cmd = "\(shellQuote(script)) \(shellQuote(NSUserName()))"
        let source = "do shell script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil && isHelperInstalled
    }

    /// Sets closed-lid sleep. Returns false if the helper is missing or the call failed.
    @discardableResult
    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        guard isHelperInstalled else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// The system's actual `disablesleep` value. Other tools (Vorssaint, Amphetamine,
    /// a manual `pmset`) can change it behind our back, so never trust a cached value.
    static var isSleepDisabled: Bool {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { return false }
        defer { IOObjectRelease(entry) }
        return (IORegistryEntryCreateCFProperty(entry, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool) ?? false
    }

    /// "AC" or "battery 87%", for the event log.
    static var powerDescription: String {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return "AC" }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            else { continue }
            return "battery \(desc[kIOPSCurrentCapacityKey] as? Int ?? -1)%"
        }
        return "AC"
    }

    /// True when running on battery below `percent`. Used as a safety cutoff so a
    /// closed laptop in a bag doesn't drain to zero.
    static func batteryBelow(_ percent: Int) -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let capacity = desc[kIOPSCurrentCapacityKey] as? Int
            else { continue }
            return capacity < percent
        }
        return false
    }

    /// True while the MacBook's lid is closed.
    static var isLidClosed: Bool {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { return false }
        defer { IOObjectRelease(entry) }
        return (IORegistryEntryCreateCFProperty(entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool) ?? false
    }

    /// An external display is connected and on. With the lid closed that means
    /// the user is working in clamshell mode, not away.
    static var externalDisplayActive: Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    /// Seconds since the user last touched the mouse, trackpad or keyboard.
    static func secondsSinceUserInput() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .keyDown, .scrollWheel, .flagsChanged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
