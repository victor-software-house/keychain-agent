import CryptoKit
import Foundation
import Security
import SSHWire

/// Stores keys as data-protection keychain items in signd's access group.
///
/// Items take the first access group of the binary's entitlements, so the store names no team.
/// They are readable after the first unlock after boot, without a prompt, and never leave this Mac.
public struct KeychainStore: KeyStore {
    static let service = "com.victor-software-house.signd.key"

    public init() {}

    private func base() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func list() throws(StoreError) -> [StoredKey] {
        var query = base()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        let items = result as? [[String: Any]] ?? []
        let decoder = PropertyListDecoder()
        return try items.map { item throws(StoreError) in
            let account = item[kSecAttrAccount as String] as? String ?? "?"
            guard let data = item[kSecValueData as String] as? Data, let key = try? decoder.decode(StoredKey.self, from: data) else {
                throw .corrupt(account)
            }
            return key
        }
        .sorted { $0.name < $1.name }
    }

    public func add(_ key: StoredKey) throws(StoreError) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(key) else { throw .corrupt(key.name) }
        var item = base()
        item[kSecAttrAccount as String] = key.name
        item[kSecAttrLabel as String] = "signd: \(key.name)"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem { throw .duplicate(key.name) }
        try check(status)
    }

    public func delete(name: String) throws(StoreError) {
        var query = base()
        query[kSecAttrAccount as String] = name
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { throw .notFound(name) }
        try check(status)
    }

    private func check(_ status: OSStatus) throws(StoreError) {
        switch status {
        case errSecSuccess: return
        case errSecInteractionNotAllowed: throw .locked
        default: throw .keychain(status)
        }
    }

    /// Makes a Secure Enclave P-256 key usable without a prompt after the first unlock.
    public static func makeSecureEnclaveKey(name: String, comment: String, hosts: [String]) throws(StoreError) -> StoredKey {
        guard SecureEnclave.isAvailable else { throw .secureEnclave("not available on this Mac") }
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil) else {
            throw .secureEnclave("access control refused")
        }
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            let publicKey = PublicKey.ecdsa(.p256, key.publicKey.x963Representation)
            return StoredKey(name: name, kind: .secureEnclave, publicBlob: publicKey.blob, comment: comment, hosts: hosts, keyData: key.dataRepresentation)
        } catch {
            throw .secureEnclave("\(error)")
        }
    }
}
