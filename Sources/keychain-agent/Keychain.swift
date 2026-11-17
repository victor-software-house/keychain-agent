import AgentProtocol
import Foundation
import Security

/// An RSA private key in the keychain, held by reference: the agent never reads its data.
struct KeychainKey {
    let label: String
    let privateKey: SecKey
    let identity: Identity
}

/// Why a labelled key could not be served.
enum KeyLookupError: Error, CustomStringConvertible {
    case notFound(label: String, status: OSStatus)
    case noPublicKey(label: String)
    case unreadablePublicKey(label: String)

    var description: String {
        switch self {
        case let .notFound(label, status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "no RSA private key labelled \(label) in the keychain: \(message)"
        case let .noPublicKey(label):
            return "the key labelled \(label) has no public key"
        case let .unreadablePublicKey(label):
            return "the public key of \(label) is not a PKCS#1 RSA key"
        }
    }
}

/// Why the keychain refused a signature.
struct SignError: Error, CustomStringConvertible {
    let label: String
    let reason: String

    var description: String { "signing with \(label) failed: \(reason)" }
}

enum Keychain {
    /// Finds the RSA private key with keychain label `label` in the user's keychain search list.
    static func key(labelled label: String) throws(KeyLookupError) -> KeychainKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item, CFGetTypeID(item) == SecKeyGetTypeID() else {
            throw .notFound(label: label, status: status)
        }
        // The type ID check above makes this cast safe; Swift has no checked cast to a CF type.
        let privateKey = item as! SecKey
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw .noPublicKey(label: label)
        }
        guard let der = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              let rsa = RSAPublicKey(pkcs1: der)
        else {
            throw .unreadablePublicKey(label: label)
        }
        return KeychainKey(label: label, privateKey: privateKey, identity: Identity(blob: rsa.sshBlob, comment: label))
    }

    /// Asks the keychain to sign `data`; the private key stays inside securityd.
    static func sign(_ data: Data, with key: KeychainKey, algorithm: SignatureAlgorithm) throws(SignError) -> Data {
        let secAlgorithm: SecKeyAlgorithm = switch algorithm {
        case .rsaSHA512: .rsaSignatureMessagePKCS1v15SHA512
        case .rsaSHA256: .rsaSignatureMessagePKCS1v15SHA256
        case .rsaSHA1: .rsaSignatureMessagePKCS1v15SHA1
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key.privateKey, secAlgorithm, data as CFData, &error) as Data? else {
            let reason = error.map { $0.takeRetainedValue().localizedDescription } ?? "no reason given"
            throw SignError(label: key.label, reason: reason)
        }
        return signature
    }
}
