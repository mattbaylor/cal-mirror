import Foundation
import Security

/// The write token in the Keychain, one generic-password item per slug.
///
/// `kSecAttrAccessibleAfterFirstUnlock` so a background refresh on iOS can
/// still poll after a reboot the owner has unlocked once; not `Always`, because
/// a token readable from a locked phone is a token readable from a stolen one.
/// Not synchronised to iCloud Keychain: the token names *this* page and the
/// page is one-per-subscription, but a second device polling the same queue
/// would race the first on resolve. That is a later decision, not an accident.
public struct KeychainTokenStore: TokenStore {
    private let service: String

    public init(service: String = "me.askwhen.write-token") { self.service = service }

    public enum Failure: Error { case status(OSStatus) }

    private func query(_ slug: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: slug]
    }

    public func token(for slug: String) throws -> String? {
        var q = query(slug)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw Failure.status(status) }
        return String(data: data, encoding: .utf8)
    }

    public func store(_ token: String, for slug: String) throws {
        let data = Data(token.utf8)
        var add = query(slug)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(query(slug) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw Failure.status(update) }
            return
        }
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    public func remove(for slug: String) throws {
        let status = SecItemDelete(query(slug) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
    }
}
