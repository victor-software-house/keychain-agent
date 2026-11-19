import Foundation
import Security

/// Where this Mac keeps the backup token.
public protocol TokenStore: Sendable {
    /// The stored token, or nil when none is stored.
    func read() throws(StoreError) -> Data?
    /// Stores the token, in place of any stored one.
    func save(_ token: Data) throws(StoreError)
    /// Deletes the stored token; none stored is no error.
    func delete() throws(StoreError)
}

/// Keeps the 1Password service account token as one data-protection keychain item in signd's access group.
///
/// It is readable after the first unlock, without a prompt, and never leaves this device.
/// It has a service name of its own, never the keys'.
public struct BackupTokenStore: TokenStore {
    static let service = "com.victor-software-house.signd.backup-token"
    static let account = "backup"

    public init() {}

    private func base() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func read() throws(StoreError) -> Data? {
        var query = base()
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let token = result as? Data else { throw .corrupt("the backup token") }
        return token
    }

    public func save(_ token: Data) throws(StoreError) {
        let update = SecItemUpdate(base() as CFDictionary, [kSecValueData as String: token] as CFDictionary)
        if update != errSecItemNotFound { return try check(update) }
        var item = base()
        item[kSecAttrLabel as String] = "signd: backup token"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = token
        let status = SecItemAdd(item as CFDictionary, nil)
        // Another signd process stored one first; this token replaces it.
        if status == errSecDuplicateItem {
            return try check(SecItemUpdate(base() as CFDictionary, [kSecValueData as String: token] as CFDictionary))
        }
        try check(status)
    }

    public func delete() throws(StoreError) {
        let status = SecItemDelete(base() as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status)
    }

    private func check(_ status: OSStatus) throws(StoreError) {
        switch status {
        case errSecSuccess: return
        case errSecInteractionNotAllowed: throw .locked
        default: throw .keychain(status)
        }
    }
}
