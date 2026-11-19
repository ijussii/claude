import Foundation
import Security
import CryptoKit

enum Keychain {
    private static let service = "app.anon.messenger"

    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    static func set(_ data: Data, for key: String) {
        SecItemDelete(base(key) as CFDictionary)
        var item = base(key)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ key: String) -> Data? {
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(_ key: String) {
        SecItemDelete(base(key) as CFDictionary)
    }
}

/// Who you are: a username, a secret login token issued by the server, and your E2E private key.
/// All three live in the Keychain; there is no email, phone number or password.
struct Identity {
    let username: String
    let token: String
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }

    static func load() -> Identity? {
        guard let u = Keychain.get("username").flatMap({ String(data: $0, encoding: .utf8) }),
              let t = Keychain.get("token").flatMap({ String(data: $0, encoding: .utf8) }),
              let k = Keychain.get("privateKey"),
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: k)
        else { return nil }
        return Identity(username: u, token: t, privateKey: key)
    }

    func save() {
        Keychain.set(Data(username.utf8), for: "username")
        Keychain.set(Data(token.utf8), for: "token")
        Keychain.set(privateKey.rawRepresentation, for: "privateKey")
    }

    static func clear() {
        ["username", "token", "privateKey"].forEach(Keychain.delete)
    }
}
