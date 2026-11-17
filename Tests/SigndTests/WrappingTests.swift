import CryptoKit
import Foundation
import KeyStore
import SSHWire
import Testing

@Suite struct WrappingRoundTrip {
    @Test func opensWhatItSealed() throws {
        let agreement = P256.KeyAgreement.PrivateKey()
        let key = try KeyImport.generate(.ed25519)
        let wrapped = try Wrapping.seal(key, comment: "wrapped", to: agreement.publicKey)
        let (opened, comment) = try Wrapping.open(wrapped, publicBlob: key.publicKey.blob, with: agreement)
        #expect(opened == key)
        #expect(comment == "wrapped")
    }

    @Test func refusesACiphertextFromAnotherWrappedKey() throws {
        let agreement = P256.KeyAgreement.PrivateKey()
        let first = try KeyImport.generate(.ed25519)
        let second = try KeyImport.generate(.ed25519)
        var wrapped = try Wrapping.seal(first, comment: "", to: agreement.publicKey)
        let other = try Wrapping.seal(second, comment: "", to: agreement.publicKey)
        wrapped.ciphertext = other.ciphertext
        #expect(throws: (any Error).self) { try Wrapping.open(wrapped, publicBlob: first.publicKey.blob, with: agreement) }
    }

    @Test func refusesAnotherPublicBlob() throws {
        let agreement = P256.KeyAgreement.PrivateKey()
        let first = try KeyImport.generate(.ed25519)
        let second = try KeyImport.generate(.ed25519)
        let wrapped = try Wrapping.seal(first, comment: "", to: agreement.publicKey)
        #expect(throws: (any Error).self) { try Wrapping.open(wrapped, publicBlob: second.publicKey.blob, with: agreement) }
    }

    @Test func refusesAnotherRecipient() throws {
        let key = try KeyImport.generate(.ed25519)
        let wrapped = try Wrapping.seal(key, comment: "", to: P256.KeyAgreement.PrivateKey().publicKey)
        #expect(throws: (any Error).self) { try Wrapping.open(wrapped, publicBlob: key.publicKey.blob, with: P256.KeyAgreement.PrivateKey()) }
    }
}
