import AgentProtocol
import Foundation
import Testing

/// A sign request body for `keyBlob`, `data` and `flags`.
private func signRequest(keyBlob: Data, data: Data, flags: UInt32) -> Data {
    var body = Data([13])
    body.appendString(keyBlob)
    body.appendString(data)
    body.appendUInt32(flags)
    return body
}

@Suite struct Requests {
    @Test func listIdentities() {
        #expect(Request(body: Data([11])) == .identities)
    }

    @Test func signWithItsFields() {
        let body = signRequest(keyBlob: Data([1, 2, 3]), data: Data("session".utf8), flags: 4)
        #expect(Request(body: body) == .sign(keyBlob: Data([1, 2, 3]), data: Data("session".utf8), flags: .rsaSHA512))
    }

    @Test func extensionIsUnsupported() {
        #expect(Request(body: Data([27, 0, 0, 0, 0])) == .unsupported(27))
    }

    @Test func emptyBodyIsMalformed() {
        #expect(Request(body: Data()) == .malformed)
    }

    @Test(arguments: [1, 5, 9])
    func signCutShortIsMalformed(keep: Int) {
        let body = signRequest(keyBlob: Data([1, 2, 3]), data: Data([4]), flags: 2)
        #expect(Request(body: body.prefix(keep)) == .malformed)
    }

    @Test func sliceWithOffsetIndices() {
        let padded = Data([0xff, 0xff]) + signRequest(keyBlob: Data([9]), data: Data([8]), flags: 0)
        #expect(Request(body: padded.dropFirst(2)) == .sign(keyBlob: Data([9]), data: Data([8]), flags: []))
    }
}

@Suite struct Algorithms {
    @Test func flagsPickTheHash() {
        #expect(SignatureAlgorithm(flags: []) == .rsaSHA1)
        #expect(SignatureAlgorithm(flags: .rsaSHA256) == .rsaSHA256)
        #expect(SignatureAlgorithm(flags: .rsaSHA512) == .rsaSHA512)
        #expect(SignatureAlgorithm(flags: [.rsaSHA256, .rsaSHA512]) == .rsaSHA512)
    }
}

@Suite struct Responses {
    @Test func failureIsOneByte() {
        #expect(Response.failure.body == Data([5]))
    }

    @Test func identitiesAnswerBytes() {
        let body = Response.identities([Identity(blob: Data([0xaa, 0xbb]), comment: "k")]).body
        #expect(body == Data([12, 0, 0, 0, 1, 0, 0, 0, 2, 0xaa, 0xbb, 0, 0, 0, 1, 0x6b]))
    }

    @Test func signatureBytes() {
        let body = Response.signature(algorithm: .rsaSHA256, bytes: Data([0x01])).body
        var signature = Data()
        signature.appendString(Data("rsa-sha2-256".utf8))
        signature.appendString(Data([0x01]))
        var expected = Data([14])
        expected.appendString(signature)
        #expect(body == expected)
    }
}

@Suite struct Frames {
    @Test func lengthWithinTheBound() {
        #expect(Frame.length(header: Data([0, 0, 1, 0])) == 256)
        #expect(Frame.length(header: Data([0, 4, 0, 0])) == Frame.maximumLength)
    }

    @Test func lengthRejected() {
        #expect(Frame.length(header: Data([0, 0, 0, 0])) == nil)
        #expect(Frame.length(header: Data([0, 4, 0, 1])) == nil)
        #expect(Frame.length(header: Data([0, 0, 1])) == nil)
    }

    @Test func encodePrefixesTheLength() {
        #expect(Frame.encode(Data([5])) == Data([0, 0, 0, 1, 5]))
    }
}

@Suite struct PublicKeys {
    /// Fixtures/rsa3072.der is a key's PKCS#1 public DER (openssl rsa -RSAPublicKey_out), and
    /// Fixtures/rsa3072.pub the same key's `ssh-keygen -y` line.
    @Test func sshBlobMatchesSSHKeygen() throws {
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let der = try Data(contentsOf: fixtures.appending(path: "rsa3072.der"))
        let line = try String(contentsOf: fixtures.appending(path: "rsa3072.pub"), encoding: .utf8)
        let fields = line.split(separator: " ")
        let expected = try #require(Data(base64Encoded: String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)))
        let key = try #require(RSAPublicKey(pkcs1: der))
        #expect(key.sshBlob == expected)
    }

    @Test func notAnRSAPublicKey() {
        #expect(RSAPublicKey(pkcs1: Data([0x02, 0x01, 0x00])) == nil)
        #expect(RSAPublicKey(pkcs1: Data([0x30, 0x84])) == nil)
        #expect(RSAPublicKey(pkcs1: Data()) == nil)
    }
}
