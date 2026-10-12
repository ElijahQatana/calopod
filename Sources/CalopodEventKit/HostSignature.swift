#if os(macOS)
import Foundation
import Security

public enum EventKitHostSignatureError: Error, Equatable, Sendable {
    case missing
    case unsigned
    case invalid
    case wrongIdentifier
    /// Ad-hoc signed and not in a development or installed layout.
    case untrusted
}

public enum EventKitHostSignature {
    public static let identifier = "pro.elijahquintana.calopod.eventkit-host"

    /// Checks the host's signature and identifier before it is launched.
    /// Ad-hoc signatures (source builds) are accepted only where the build
    /// and install scripts put the host: `.build/eventkit-host` and the
    /// per-user `Service/eventkit-host`. Anything else needs a team signature.
    public static func verify(appURL: URL) throws {
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw EventKitHostSignatureError.missing
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw EventKitHostSignatureError.invalid
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate
            | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(staticCode, flags, nil)
        if status == errSecCSUnsigned { throw EventKitHostSignatureError.unsigned }
        guard status == errSecSuccess else { throw EventKitHostSignatureError.invalid }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess, let details = information as? [String: Any] else {
            throw EventKitHostSignatureError.invalid
        }
        guard details[kSecCodeInfoIdentifier as String] as? String == identifier else {
            throw EventKitHostSignatureError.wrongIdentifier
        }
        if details[kSecCodeInfoTeamIdentifier as String] == nil, !isTrustedLayout(appURL) {
            throw EventKitHostSignatureError.untrusted
        }
    }

    static func isTrustedLayout(_ appURL: URL) -> Bool {
        let parent = appURL.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        guard parent.lastPathComponent == "eventkit-host" else { return false }
        return [".build", "Service"].contains(parent.deletingLastPathComponent().lastPathComponent)
    }
}
#endif
