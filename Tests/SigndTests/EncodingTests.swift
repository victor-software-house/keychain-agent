import Foundation
import SSHEncoding
import Testing

@Suite struct Encoding {
    @Test func mpintAddsAZeroBeforeATopBit() {
        var data = Data()
        data.appendMPInt(unsigned: Data([0x80, 0x01]))
        #expect(data == Data([0, 0, 0, 3, 0x00, 0x80, 0x01]))
    }

    @Test func mpintDropsLeadingZerosAndWritesZeroEmpty() {
        var data = Data()
        data.appendMPInt(unsigned: Data([0, 0, 0x7f]))
        data.appendMPInt(unsigned: Data([0, 0]))
        #expect(data == Data([0, 0, 0, 1, 0x7f, 0, 0, 0, 0]))
    }

    @Test func readerRefusesCutFields() {
        var reader = Reader(Data([0, 0, 0, 5, 1, 2]))
        #expect(reader.readString() == nil)
    }

    @Test func readerRefusesNegativeMPInt() {
        var reader = Reader(Data([0, 0, 0, 1, 0x80]))
        #expect(reader.readUnsignedMPInt() == nil)
    }
}

@Suite struct PublicKeys {
    func fixtureLine() throws -> [Substring] {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/rsa3072", withExtension: "pub"))
        return try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isWhitespace)
    }

    @Test func rsaBlobRoundTripsAndMatchesSSHKeygen() throws {
        let blob = try #require(Data(base64Encoded: String(try fixtureLine()[1])))
        let key = try #require(PublicKey(blob: blob))
        #expect(key.keyType == "ssh-rsa")
        #expect(key.blob == blob)
        #expect(key.rsaBits == 3072)
        #expect(key.fingerprint == "SHA256:F6s91DgRhGwWKnbf+4+ijO2tuz2tiCt/K2b95tEe54g")
    }

    @Test func trailingBytesAreRefused() throws {
        let blob = try #require(Data(base64Encoded: String(try fixtureLine()[1])))
        #expect(PublicKey(blob: blob + Data([0])) == nil)
    }

    @Test func ecdsaBlobRoundTrips() {
        let key = PublicKey.ecdsa(.p256, Data([4] + Array(repeating: 7, count: 64)))
        #expect(PublicKey(blob: key.blob) == key)
        #expect(key.keyType == "ecdsa-sha2-nistp256")
    }
}

@Suite struct PrivateKeys {
    @Test(arguments: [
        PrivateKey.ed25519(seed: Data(repeating: 1, count: 32), publicKey: Data(repeating: 2, count: 32)),
        PrivateKey.ecdsa(.p384, point: Data([4] + Array(repeating: 3, count: 96)), scalar: Data(repeating: 0x81, count: 48)),
        PrivateKey.rsa(n: Data([0xc1, 2, 3]), e: Data([1, 0, 1]), d: Data([4]), iqmp: Data([5]), p: Data([6]), q: Data([7])),
    ])
    func layoutRoundTrips(key: PrivateKey) {
        var data = Data()
        key.write(to: &data)
        var reader = Reader(data)
        #expect(PrivateKey.read(from: &reader) == key)
        #expect(reader.isAtEnd)
    }

    @Test func ed25519WithAMismatchedPublicHalfIsRefused() {
        var data = Data()
        data.appendString("ssh-ed25519")
        data.appendString(Data(repeating: 2, count: 32))
        data.appendString(Data(repeating: 1, count: 32) + Data(repeating: 9, count: 32))
        var reader = Reader(data)
        #expect(PrivateKey.read(from: &reader) == nil)
    }
}
