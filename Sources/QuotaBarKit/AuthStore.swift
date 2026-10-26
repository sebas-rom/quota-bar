import Foundation
import Security

// MARK: - Credential discovery (read-only, never logged)
//
// Go key priority:
//   1. macOS Keychain (entered in-app via "Enter API key…")
//   2. ~/.config/quota-bar/opencode-go.json {"apiKey": "..."} (optional override)
//   3. $OPENCODE_GO_API_KEY (optional override)
//   4. opencode auth.json "opencode-go" entry (XDG_DATA_HOME, ~/.local/share, ~/Library/Application Support)
// Codex: ~/.codex/auth.json tokens.access_token + account_id (unchanged).

public let quotaBarService = "com.quota.bar"
public let quotaBarGoAccount = "opencode-go"

public func saveKeychainKey(service: String = quotaBarService, account: String, value: String) -> Bool {
    let data = Data(value.utf8)
    let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
    SecItemDelete(base as CFDictionary)
    var add = base
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
}

public func loadKeychainKey(service: String = quotaBarService, account: String) -> String? {
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data,
          let s = String(data: data, encoding: .utf8),
          !s.isEmpty else { return nil }
    return s
}

public func deleteKeychainKey(service: String = quotaBarService, account: String) {
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
    SecItemDelete(q as CFDictionary)
}

public struct KeyCandidate {
    public let source: String
    public let key: String
}

public func homeDir() -> URL { FileManager.default.homeDirectoryForCurrentUser }

public func goKeyCandidates() -> [KeyCandidate] {
    var out: [KeyCandidate] = []
    func add(_ source: String, _ key: String?) {
        guard let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return }
        if !out.contains(where: { $0.key == k }) { out.append(KeyCandidate(source: source, key: k)) }
    }
    add("Keychain", loadKeychainKey(account: quotaBarGoAccount))
    let override = homeDir().appendingPathComponent(".config/quota-bar/opencode-go.json")
    if let data = try? Data(contentsOf: override),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        add(override.path, obj["apiKey"] as? String)
    }
    let env = ProcessInfo.processInfo.environment
    add("OPENCODE_GO_API_KEY", env["OPENCODE_GO_API_KEY"])
    var authPaths: [URL] = []
    if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty {
        authPaths.append(URL(fileURLWithPath: NSString(string: xdg).expandingTildeInPath).appendingPathComponent("opencode/auth.json"))
    }
    authPaths.append(homeDir().appendingPathComponent(".local/share/opencode/auth.json"))
    authPaths.append(homeDir().appendingPathComponent("Library/Application Support/opencode/auth.json"))
    for url in authPaths {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        if let entry = obj["opencode-go"] as? [String: Any] {
            for k in ["key", "access", "token", "apiKey", "value"] {
                add("opencode auth.json", entry[k] as? String)
            }
        } else if let s = obj["opencode-go"] as? String {
            add("opencode auth.json", s)
        }
        if out.count >= 4 { break }
    }
    return out
}

public struct CodexCreds {
    public let token: String
    public let accountId: String?
}

public func readCodexCreds() -> CodexCreds? {
    let url = homeDir().appendingPathComponent(".codex/auth.json")
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let t = obj["tokens"] as? [String: Any],
          let access = t["access_token"] as? String, !access.isEmpty else { return nil }
    let aid = (t["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    return CodexCreds(token: access, accountId: aid)
}
