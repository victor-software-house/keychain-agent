import CryptoKit
import Foundation
import Security

/// This device's Secure Enclave key-agreement key, to which every device seals the keys it shares.
public struct DeviceKey: Sendable, Equatable {
    /// The Secure Enclave handle, which opens only on this device.
    public let handle: Data
    /// The X9.63 form of the public key.
    public let publicKey: Data

    public init(handle: Data, publicKey: Data) {
        self.handle = handle
        self.publicKey = publicKey
    }

    /// This device's record name: `device-` and the first 16 bytes of the public key's SHA-256, in hex.
    public var recordName: String { Self.recordName(for: publicKey) }

    public static func recordName(for publicKey: Data) -> String {
        "device-" + SHA256.hash(data: publicKey).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Keeps the device key's handle as one data-protection keychain item in signd's access group.
///
/// It is readable after the first unlock, without a prompt, and never leaves this device.
public struct DeviceKeyStore: Sendable {
    static let service = "com.victor-software-house.signd.device"
    static let account = "device"

    public init() {}

    private func base() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// The device key, made and stored the first time it is asked for.
    public func readOrCreate() throws(StoreError) -> DeviceKey {
        if let key = try read() { return key }
        guard SecureEnclave.isAvailable else { throw .secureEnclave("not available on this Mac") }
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil) else {
            throw .secureEnclave("access control refused")
        }
        let key: SecureEnclave.P256.KeyAgreement.PrivateKey
        do {
            key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        } catch {
            throw .secureEnclave("\(error)")
        }
        var item = base()
        item[kSecAttrLabel as String] = "signd: device key"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = key.dataRepresentation
        let status = SecItemAdd(item as CFDictionary, nil)
        // Another signd process stored one first; that one is the device key.
        if status == errSecDuplicateItem, let stored = try read() { return stored }
        try check(status)
        return DeviceKey(handle: key.dataRepresentation, publicKey: key.publicKey.x963Representation)
    }

    /// The stored device key, or nil when none is stored.
    public func read() throws(StoreError) -> DeviceKey? {
        var query = base()
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let handle = result as? Data, let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: handle) else {
            throw .corrupt("the device key")
        }
        return DeviceKey(handle: handle, publicKey: key.publicKey.x963Representation)
    }

    private func check(_ status: OSStatus) throws(StoreError) {
        switch status {
        case errSecSuccess: return
        case errSecInteractionNotAllowed: throw .locked
        default: throw .keychain(status)
        }
    }
}
