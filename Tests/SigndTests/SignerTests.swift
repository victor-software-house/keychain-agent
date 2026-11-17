import AgentProtocol
import CryptoExtras
import CryptoKit
import Foundation
import KeyStore
import SSHWire
import Testing

/// RSA keys made for these tests only, as hex numbers.
func testRSAKey(_ name: String) throws -> PrivateKey {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/rsa-test-keys", withExtension: "json"))
    let keys = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: url))
    let numbers = try #require(keys[name])
    func number(_ field: String) throws -> Data {
        let hex = try #require(numbers[field])
        return Data(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }
    return .rsa(n: try number("n"), e: try number("e"), d: try number("d"), iqmp: try number("iqmp"), p: try number("p"), q: try number("q"))
}

@Suite struct Signers {
    let data = Data("signed data".utf8)

    @Test func ed25519Verifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signer = try SoftwareSigner(.ed25519(seed: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation))
        let signature = try signer.sign(data, flags: [])
        #expect(signature.algorithm == "ssh-ed25519")
        #expect(key.publicKey.isValidSignature(signature.bytes, for: data))
    }

    @Test func ed25519WithAnotherPublicKeyIsRefused() {
        let key = Curve25519.Signing.PrivateKey()
        #expect(throws: SignError.self) {
            try SoftwareSigner(.ed25519(seed: key.rawRepresentation, publicKey: Data(repeating: 0, count: 32)))
        }
    }

    @Test func p256Verifies() throws {
        let key = P256.Signing.PrivateKey()
        let signer = try SoftwareSigner(.ecdsa(.p256, point: key.publicKey.x963Representation, scalar: key.rawRepresentation))
        let signature = try signer.sign(data, flags: [])
        #expect(signature.algorithm == "ecdsa-sha2-nistp256")
        var reader = Reader(signature.bytes)
        let (r, s) = (reader.unsignedMPInt() ?? Data(), reader.unsignedMPInt() ?? Data())
        func padded(_ value: Data) -> Data { Data(repeating: 0, count: 32 - value.count) + value }
        let raw = try P256.Signing.ECDSASignature(rawRepresentation: padded(r) + padded(s))
        #expect(key.publicKey.isValidSignature(raw, for: data))
    }

    @Test(arguments: [(SignFlags.rsaSHA256, "rsa-sha2-256"), (.rsaSHA512, "rsa-sha2-512"), (SignFlags(), "ssh-rsa")])
    func rsaSignsWithTheRequestedHash(flags: SignFlags, algorithm: String) throws {
        let privateKey = try testRSAKey("rsa2048")
        guard case let .rsa(n, e, _, _, _, _) = privateKey else { return }
        let signature = try SoftwareSigner(privateKey).sign(data, flags: flags)
        #expect(signature.algorithm == algorithm)
        let publicKey = try _RSA.Signing.PublicKey(n: n, e: e)
        let bytes = _RSA.Signing.RSASignature(rawRepresentation: signature.bytes)
        let valid = switch algorithm {
        case "rsa-sha2-256": publicKey.isValidSignature(bytes, for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5)
        case "rsa-sha2-512": publicKey.isValidSignature(bytes, for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5)
        default: publicKey.isValidSignature(bytes, for: Insecure.SHA1.hash(data: data), padding: .insecurePKCS1v1_5)
        }
        #expect(valid)
    }

    @Test func rsaUnder2048BitsIsRefused() throws {
        let key = try testRSAKey("rsa1024")
        #expect(throws: SignError.self) { try SoftwareSigner(key) }
    }
}
