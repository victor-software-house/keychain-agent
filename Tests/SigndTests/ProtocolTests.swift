import AgentProtocol
import Foundation
import SSHEncoding
import Testing

private let ed25519 = PrivateKey.ed25519(seed: Data(repeating: 1, count: 32), publicKey: Data(repeating: 2, count: 32))

private func addBody(constrained: Bool, comment: String = "work", constraints: Data = Data()) -> Data {
    var body = Data([constrained ? 25 : 17])
    ed25519.write(to: &body)
    body.appendString(comment)
    body.append(constraints)
    return body
}

@Suite struct Requests {
    @Test func identities() {
        #expect(Request(body: Data([11])) == .identities)
    }

    @Test func signCarriesItsFlags() {
        var body = Data([13])
        body.appendString(Data([1, 2]))
        body.appendString(Data("session".utf8))
        body.appendUInt32(2)
        #expect(Request(body: body) == .sign(keyBlob: Data([1, 2]), data: Data("session".utf8), flags: .rsaSHA256))
    }

    @Test func addWithoutConstraints() {
        #expect(Request(body: addBody(constrained: false)) == .add(key: ed25519, comment: "work", constraints: Constraints()))
    }

    @Test func addWithLifetimeAndConfirm() {
        var constraints = Data([1])
        constraints.appendUInt32(30)
        constraints.append(2)
        let request = Request(body: addBody(constrained: true, constraints: constraints))
        #expect(request == .add(key: ed25519, comment: "work", constraints: Constraints(lifetime: 30, requiresConfirmation: true)))
    }

    @Test func addWithAnExtensionConstraint() {
        var constraints = Data([255])
        constraints.appendString("restrict-destination-v00@openssh.com")
        constraints.append(contentsOf: [1, 2, 3])
        let request = Request(body: addBody(constrained: true, constraints: constraints))
        #expect(request == .add(key: ed25519, comment: "work", constraints: Constraints(extensions: ["restrict-destination-v00@openssh.com"])))
    }

    @Test func unknownConstraintIsMalformed() {
        #expect(Request(body: addBody(constrained: true, constraints: Data([9]))) == .malformed)
    }

    @Test func removeAndRemoveAll() {
        var body = Data([18])
        body.appendString(Data([7]))
        #expect(Request(body: body) == .remove(keyBlob: Data([7])))
        #expect(Request(body: Data([19])) == .removeAll)
    }

    @Test func extensionNameAndContents() {
        var body = Data([27])
        body.appendString("session-bind@openssh.com")
        body.append(contentsOf: [9, 9])
        #expect(Request(body: body) == .extension(name: "session-bind@openssh.com", contents: Data([9, 9])))
    }

    @Test func lockIsUnsupported() {
        #expect(Request(body: Data([22])) == .unsupported(22))
    }

    @Test(arguments: [Data(), Data([13, 0, 0]), Data([18, 0, 0, 0, 9])])
    func cutOrEmptyBodiesAreMalformed(body: Data) {
        #expect(Request(body: body) == .malformed)
    }
}

@Suite struct Responses {
    @Test func failureAndSuccessAreOneByte() {
        #expect(Response.failure.body == Data([5]))
        #expect(Response.success.body == Data([6]))
    }

    @Test func identitiesList() {
        var expected = Data([12, 0, 0, 0, 1])
        expected.appendString(Data([1]))
        expected.appendString("a")
        #expect(Response.identities([Identity(blob: Data([1]), comment: "a")]).body == expected)
    }

    @Test func signatureWrapsItsBlob() {
        let signature = Signature(algorithm: "rsa-sha2-256", bytes: Data([1, 2]))
        var expected = Data([14])
        expected.appendString(signature.blob)
        #expect(Response.signature(signature).body == expected)
    }

    @Test func queryListsTheSupportedExtensions() {
        var reader = Reader(Response.query.body)
        #expect(reader.readByte() == 29)
        #expect(reader.readText() == "query")
        #expect(reader.readText() == "query")
        #expect(reader.readText() == "session-bind@openssh.com")
        #expect(reader.isAtEnd)
    }

    static let flagCases: [(SignFlags, RSAAlgorithm)] = [(SignFlags(), .sha1), (.rsaSHA256, .sha256), (.rsaSHA512, .sha512), ([.rsaSHA256, .rsaSHA512], .sha512)]

    @Test(arguments: flagCases)
    func rsaFlagsPickTheHash(flags: SignFlags, algorithm: RSAAlgorithm) {
        #expect(RSAAlgorithm(flags: flags) == algorithm)
    }
}
