import Foundation
import Security

/// The 1Password service account token, as one data-protection keychain item in signd's access group.
///
/// It is readable after the first unlock, without a prompt, and never leaves this Mac.
public struct TokenStore: Sendable {
    static let service = "com.victor-software-house.signd.token"
    static let account = "token"

    public init() {}

    private func base() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// The stored token, or nil when none is stored.
    public func read() throws(StoreError) -> String? {
        var query = base()
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw .corrupt("the token") }
        return token
    }

    public var isStored: Bool {
        var query = base()
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Stores `token`, replacing one stored before.
    public func write(_ token: String) throws(StoreError) {
        var item = base()
        item[kSecAttrLabel as String] = "signd: 1Password token"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try check(SecItemUpdate(base() as CFDictionary, [kSecValueData as String: Data(token.utf8)] as CFDictionary))
        } else {
            try check(status)
        }
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
