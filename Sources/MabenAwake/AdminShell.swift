import Foundation

/// Text that goes into AppleScript source.
enum AppleScript {
    /// `s` as an AppleScript string, quotes included. Anything in a script that
    /// isn't written out in this app's own source goes through here, so it can
    /// never end the string and continue as script.
    static func string(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(c)
            }
        }
        return out + "\""
    }
}

/// Shell commands that run as root after a password prompt
/// (`do shell script … with administrator privileges`). Every place that asks
/// for the administrator password builds its script here.
enum AdminShell {
    enum Outcome { case done, cancelled, failed }

    /// `s` as one word for `/bin/sh`.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The AppleScript that runs `command` as root.
    static func source(_ command: String, prompt: String? = nil) -> String {
        "do shell script " + AppleScript.string(command)
            + (prompt.map { " with prompt " + AppleScript.string($0) } ?? "")
            + " with administrator privileges"
    }

    /// Runs `command` as root in a separate `osascript` process, so the password
    /// dialog never blocks the main thread (which has to keep watching the lid).
    static func run(_ command: String, prompt: String, completion: @escaping @Sendable (Outcome) -> Void) {
        let (p, errors) = osascript(command, prompt: prompt)
        p.terminationHandler = { completion(outcome(of: $0, errors: errors)) }
        do { try p.run() } catch { completion(.failed) }
    }

    /// The same, waiting for it to finish. Not for the main thread.
    static func runAndWait(_ command: String, prompt: String) -> Outcome {
        let (p, errors) = osascript(command, prompt: prompt)
        do { try p.run() } catch { return .failed }
        p.waitUntilExit()
        return outcome(of: p, errors: errors)
    }

    private static func osascript(_ command: String, prompt: String) -> (Process, Pipe) {
        let p = Process(), errors = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source(command, prompt: prompt)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errors
        return (p, errors)
    }

    private static func outcome(of p: Process, errors: Pipe) -> Outcome {
        if p.terminationStatus == 0 { return .done }
        // osascript always says why it failed; -128 is Cancel in the password dialog.
        let message = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
        return message.contains("(-128)") ? .cancelled : .failed
    }
}
