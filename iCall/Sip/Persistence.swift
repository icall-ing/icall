import Foundation
import Security

/// Saved sign-in (Line 1). Mirrors Android's persisted SipAccountConfig so the
/// app can auto-register on launch — required for PushKit to wake a closed app
/// into a re-registration, and nicer UX (no re-sign-in each launch).
struct SavedAccount: Codable {
    var username: String
    var password: String
    var server: String
    var transport: String   // "tcp" | "tls"
    var srtp: String?       // "disabled"(default) | "optional" | "mandatory"
    var aor: String { "\(username)@\(server)" }
}

enum AccountStore {
    private static func key(_ line: Int) -> String {
        line == 1 ? "ing.icall.dialer.account.line2" : "ing.icall.dialer.account.line1"
    }

    static func save(_ a: SavedAccount, line: Int = 0) {
        guard let data = try? JSONEncoder().encode(a) else { return }
        Keychain.set(data, account: key(line))
    }
    static func load(line: Int = 0) -> SavedAccount? {
        guard let data = Keychain.get(account: key(line)),
              let a = try? JSONDecoder().decode(SavedAccount.self, from: data) else { return nil }
        return a
    }
    static func clear(line: Int = 0) { Keychain.delete(account: key(line)) }
}

/// Minimal Keychain wrapper (generic password items).
enum Keychain {
    static func set(_ data: Data, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
