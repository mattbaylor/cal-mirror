import Foundation
import Security

/// The write token in the Keychain, one generic-password item per slug,
/// synchronized through iCloud Keychain.
///
/// There is no account, no password and no address on file for an owner, so
/// this item is the only thing that proves a page is theirs. On one device
/// only, a lost phone or a reinstall with no second device orphaned the page:
/// still serving, never again publishable, answerable or switchable off.
/// `kSecAttrSynchronizable` makes the key follow the Apple Account instead —
/// end-to-end encrypted, the way Safari's passwords travel — so a new device
/// finds it, and `slugs()` is how the app learns which page it has a key to.
/// An owner with iCloud Keychain off keeps the one-device behaviour, and the
/// copy says so.
///
/// `kSecAttrAccessibleAfterFirstUnlock` so a background refresh on iOS can
/// still poll after a reboot the owner has unlocked once; not `Always`,
/// because a token readable from a locked phone is a token readable from a
/// stolen one. (A synchronizable item cannot be `ThisDeviceOnly`, which is
/// the point.)
///
/// A second device holding the token collects the same queue, which is the
/// design — one publisher, any number of collectors — and the service refuses
/// the second resolve of a request with a 404 the coordinator reads as
/// "already gone". What that does not stop is two devices both writing the
/// event before either learns the other accepted; `decisions.md`, *Accept
/// should claim on the service before it writes*.
public struct KeychainTokenStore: TokenStore {
    private let service: String

    public init(service: String = "me.askwhen.write-token") { self.service = service }

    public enum Failure: Error { case status(OSStatus) }

    /// Matches the item whether or not it is synchronized, so a token stored
    /// before 2.0 (local only) is still found — and migrated on first read.
    private func query(_ slug: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: slug,
         kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
    }

    public func token(for slug: String) throws -> String? {
        var q = query(slug)
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item = out as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let token = String(data: data, encoding: .utf8) else { throw Failure.status(status) }
        // A pre-2.0 item is local-only. Re-store it as synchronizable and drop
        // the local one, so the next device finds it. Best effort: a failure
        // here leaves the working local token in place.
        let synced = (item[kSecAttrSynchronizable as String] as? Bool) ?? false
        if !synced {
            var local = query(slug)
            local[kSecAttrSynchronizable as String] = false
            if (try? store(token, for: slug)) != nil { SecItemDelete(local as CFDictionary) }
        }
        return token
    }

    public func store(_ token: String, for slug: String) throws {
        let data = Data(token.utf8)
        var add = query(slug)
        add[kSecAttrSynchronizable as String] = true
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            var find = query(slug)
            find[kSecAttrSynchronizable as String] = true
            let update = SecItemUpdate(find as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw Failure.status(update) }
            return
        }
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    public func remove(for slug: String) throws {
        let status = SecItemDelete(query(slug) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
    }

    public func slugs() throws -> [String] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        q[kSecReturnData as String] = false
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = out as? [[String: Any]] else { throw Failure.status(status) }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}
