import Foundation
import Security

/// Ad-hoc signed builds have no team identifier, and macOS silently refuses to
/// register them with Notification Center. Used to pick the delivery path.
enum SignatureInfo {
    static let isAdHoc: Bool = {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return true }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return true }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        return (team ?? "").isEmpty
    }()
}
