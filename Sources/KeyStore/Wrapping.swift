import CryptoKit
import Foundation
import SSHEncoding

/// A private key sealed with Hybrid Public Key Encryption (HPKE) to a key-agreement key, as a wrapped key's keychain item stores it.
public struct WrappedKey: Codable, Sendable, Equatable {
    /// The sender's ephemeral public key, which the recipient needs to open the ciphertext.
    public var encapsulatedKey: Data
    public var ciphertext: Data

    public init(encapsulatedKey: Data, ciphertext: Data) {
        self.encapsulatedKey = encapsulatedKey
        self.ciphertext = ciphertext
    }
}

/// A secret, such as the backup token, sealed with HPKE to a key-agreement key.
public struct SealedSecret: Codable, Sendable, Equatable {
    /// The sender's ephemeral public key, which the recipient needs to open the ciphertext.
    public var encapsulatedKey: Data
    public var ciphertext: Data

    public init(encapsulatedKey: Data, ciphertext: Data) {
        self.encapsulatedKey = encapsulatedKey
        self.ciphertext = ciphertext
    }
}

public enum WrappingError: Error, Sendable, Equatable, CustomStringConvertible {
    case malformed(String)

    public var description: String {
        switch self {
        case let .malformed(reason): "wrapped key: \(reason)"
        }
    }
}

/// Seals and opens private keys with HPKE, so only the owner of one key-agreement key can read them.
public enum Wrapping {
    static let ciphersuite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256
    static let info = Data("signd wrapped key v1".utf8)
    static let secretInfo = Data("signd backup token v1".utf8)

    /// The key's type name and public blob, which bind the ciphertext to its public key.
    private static func authenticatedData(type: String, publicBlob: Data) -> Data {
        var data = Data()
        data.appendString(type)
        data.appendString(publicBlob)
        return data
    }

    public static func seal(_ key: PrivateKey, comment: String, to recipient: P256.KeyAgreement.PublicKey) throws -> WrappedKey {
        var plaintext = Data()
        key.write(to: &plaintext)
        plaintext.appendString(comment)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: ciphersuite, info: info)
        let aad = authenticatedData(type: key.publicKey.keyType, publicBlob: key.publicKey.blob)
        let ciphertext = try sender.seal(plaintext, authenticating: aad)
        return WrappedKey(encapsulatedKey: sender.encapsulatedKey, ciphertext: ciphertext)
    }

    /// Opens a wrapped key and checks that it belongs to `publicBlob`.
    public static func open(_ wrapped: WrappedKey, publicBlob: Data, with privateKey: some HPKEDiffieHellmanPrivateKey) throws -> (PrivateKey, String) {
        guard let publicKey = PublicKey(blob: publicBlob) else { throw WrappingError.malformed("the public key is unreadable") }
        var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: ciphersuite, info: info, encapsulatedKey: wrapped.encapsulatedKey)
        var plaintext = try recipient.open(wrapped.ciphertext, authenticating: authenticatedData(type: publicKey.keyType, publicBlob: publicBlob))
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        var reader = Reader(plaintext)
        guard let key = PrivateKey.read(from: &reader), let comment = reader.readText(), reader.isAtEnd else {
            throw WrappingError.malformed("the private key is unreadable")
        }
        guard key.publicKey.blob == publicBlob else { throw WrappingError.malformed("the private key belongs to another public key") }
        return (key, comment)
    }
}

extension Wrapping {
    /// Seals bytes to a key-agreement key, under an info string of its own, so a sealed key never opens as a secret.
    public static func seal(secret: Data, to recipient: P256.KeyAgreement.PublicKey) throws -> SealedSecret {
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: ciphersuite, info: secretInfo)
        let ciphertext = try sender.seal(secret, authenticating: Data())
        return SealedSecret(encapsulatedKey: sender.encapsulatedKey, ciphertext: ciphertext)
    }

    /// Opens a sealed secret with the device's key-agreement key.
    public static func open(_ sealed: SealedSecret, with privateKey: some HPKEDiffieHellmanPrivateKey) throws -> Data {
        var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: ciphersuite, info: secretInfo, encapsulatedKey: sealed.encapsulatedKey)
        return try recipient.open(sealed.ciphertext, authenticating: Data())
    }

    /// Opens a sealed secret with the device's Secure Enclave key-agreement key, whose handle is `handle`.
    public static func openSecret(_ sealed: SealedSecret, handle: Data) throws -> Data {
        try open(sealed, with: SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: handle))
    }

    /// Opens a stored wrapped key with its Secure Enclave key-agreement key, whose handle is `keyData`, and returns the private key and its comment.
    public static func openStored(_ key: StoredKey) throws(SignError) -> (PrivateKey, String) {
        guard let wrapped = key.wrapped else { throw .invalidKey("\(key.name) has no wrapped key") }
        do {
            let agreement = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: key.keyData)
            return try open(wrapped, publicBlob: key.publicBlob, with: agreement)
        } catch {
            throw .invalidKey("\(error)")
        }
    }
}

extension SoftwareSigner {
    /// Opens a wrapped key with its Secure Enclave key-agreement key, whose handle is `keyData`.
    public init(opening key: StoredKey) throws(SignError) {
        try self.init(Wrapping.openStored(key).0)
    }
}
