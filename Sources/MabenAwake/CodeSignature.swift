import Foundation
import Security

/// Code signature checks in this process. Where root acts on the result, root
/// repeats the check with `codesign` on a copy only it can change (see
/// `Updater.rootInstallCommand` and `RootInstall`).
enum CodeSignature {
    /// `(identifier "a" or identifier "b")` for a code requirement. An ID with
    /// anything but letters, digits, dots and hyphens is left out, so an ID can
    /// never change what the rest of the requirement says.
    static func identifiers(_ ids: [String]) -> String {
        let safe = ids.filter { !$0.isEmpty && $0.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") } }
        return "(" + safe.map { "identifier \"\($0)\"" }.joined(separator: " or ") + ")"
    }

    /// Whether the app on disk at `app` has a valid signature that satisfies
    /// `requirement`: every architecture, strictly, nested code included.
    static func satisfies(_ app: URL, _ requirement: String) -> Bool {
        var code: SecStaticCode?
        var parsed: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, parsed) == errSecSuccess
    }

    /// The hardened runtime, in the kernel's flags for a running process
    /// (`CS_RUNTIME`). Every release runs with it; a development build doesn't
    /// (`build.sh` signs ad hoc, without it).
    static let hardenedRuntime: UInt32 = 0x10000

    /// Whether root has to check the app's signature before it runs anything
    /// from the app. Only a development build is let off, since it could never
    /// pass. `satisfies`: the running app meets the requirement. `status`: the
    /// kernel's flags for this process, nil if they can't be read.
    ///
    /// The running app failing the requirement is not enough to call it a
    /// development build: a release fails it too once its files on disk were
    /// changed, which is exactly when root must look. The kernel's flags were
    /// set when this process started and nothing on disk changes them.
    static func rootMustCheck(satisfies: Bool, status: UInt32?) -> Bool {
        if satisfies { return true }
        guard let status else { return true }
        return status & hardenedRuntime != 0
    }

    /// `rootMustCheck` for the running app and `requirement`.
    static func rootMustCheckRunningApp(_ requirement: String) -> Bool {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return true }
        var parsed: SecRequirement?
        let satisfies = SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess
            && SecCodeCheckValidity(me, [], parsed) == errSecSuccess
        // The call takes running code as well as code on disk; Swift only knows the second type.
        var info: CFDictionary?
        let read = SecCodeCopySigningInformation(unsafeBitCast(me, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSDynamicInformation), &info)
        let status = read == errSecSuccess ? ((info as? [String: Any])?[kSecCodeInfoStatus as String] as? NSNumber)?.uint32Value : nil
        return rootMustCheck(satisfies: satisfies, status: status)
    }
}
