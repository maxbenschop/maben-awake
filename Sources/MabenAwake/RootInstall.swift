import Foundation

/// The command root runs to install the lid helper (the sudoers rule) and the
/// lid-open failsafe.
///
/// The install scripts and the failsafe binary ship inside the app, and on a
/// normal install the app's files belong to the user: any process of that user
/// could change them and wait for the next password prompt. So root never runs
/// them where they are. It copies the whole app into a folder only root can
/// open, checks the signature of that copy, and runs the scripts and installs
/// the binary from the copy.
enum RootInstall {
    enum Action: Equatable {
        /// The sudoers rule for `user` and, with `failsafe`, the lid-open failsafe
        /// in the same password prompt (if that part fails, the rule stays).
        case lidHelper(user: String, failsafe: Bool)
        /// The lid-open failsafe on its own: install or update.
        case failsafe
    }

    /// What the copy must be: signed by our team under one of our bundle IDs.
    /// Less than an update has to be (`Updater.requirement`): this is the app
    /// that is already running, not something from the network, so a build
    /// signed with the team's development certificate passes and notarization
    /// isn't asked for.
    static func requirement(identifiers: [String] = Updater.acceptedIdentifiers) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(Updater.teamID)\" and " + CodeSignature.identifiers(identifiers)
    }

    /// The shell command for `action`, run from the app at `app`. `requirement`
    /// is nil for a development build, whose ad-hoc signature has nothing to
    /// check: the same steps without the check.
    static func command(app: String, action: Action, requirement: String?) -> String {
        let q = AdminShell.quote
        var lines = [
            // mktemp makes the folder for root alone; the chmod only says so again.
            "D=$(/usr/bin/mktemp -d /private/tmp/maben-awake.XXXXXXXX) || exit 1",
            #"trap '/bin/rm -rf "$D"' EXIT"#,
            #"A="$D/Maben Awake.app""#,
            #"/bin/chmod 700 "$D" || exit 1"#,
            #"/usr/bin/ditto \#(q(app)) "$A" || exit 1"#,
            #"/usr/sbin/chown -R root:wheel "$A" || exit 1"#,
        ]
        if let requirement {
            lines.append(#"/usr/bin/codesign --verify --deep --strict -R=\#(q(requirement)) "$A" || exit 1"#)
        }
        let failsafe = #""$A/Contents/Resources/install-failsafe.sh" "$A/Contents/MacOS/maben-awake-failsafe""#
        switch action {
        case .lidHelper(let user, let withFailsafe):
            lines.append(#""$A/Contents/Resources/install-lid-helper.sh" \#(q(user)) || exit 1"#)
            if withFailsafe { lines.append(failsafe + " || true") }
        case .failsafe:
            lines.append(failsafe + " || exit 1")
        }
        return lines.joined(separator: "\n")
    }

    /// `command` for the running app. Decides here whether root checks the
    /// signature (every release) or can't (a development build), and logs which.
    static func commandForRunningApp(_ action: Action) -> String {
        let requirement = requirement()
        let check = CodeSignature.rootMustCheckRunningApp(requirement)
        EventLog.write(check ? "installing as root: root checks the app's signature first"
                             : "installing as root: development build, no signature to check")
        return command(app: Bundle.main.bundlePath, action: action, requirement: check ? requirement : nil)
    }
}
