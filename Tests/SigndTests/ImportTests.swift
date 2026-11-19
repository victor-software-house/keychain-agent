import AgentProtocol
import CryptoKit
import Foundation
import KeyStore
import SSHEncoding
import Testing

/// A directory for one test, removed when the test ends.
struct TestDirectory: ~Copyable {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("importtest-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
}

/// A key file `ssh-keygen` wrote, with the public blob from its `.pub` file.
struct GeneratedFile {
    let path: String
    let publicBlob: Data
    var contents: Data { FileManager.default.contents(atPath: path) ?? Data() }
}

/// Runs `/usr/bin/ssh-keygen` for a key of `arguments` in `directory`.
func sshKeygen(in directory: borrowing TestDirectory, _ arguments: [String], passphrase: String = "", comment: String = "test") throws -> GeneratedFile {
    let path = directory.path("key-\(UUID().uuidString.prefix(8))")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    process.arguments = ["-q"] + arguments + ["-N", passphrase, "-C", comment, "-f", path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    let line = try String(contentsOfFile: path + ".pub", encoding: .utf8)
    let field = try #require(line.split(separator: " ").dropFirst().first)
    let blob = try #require(Data(base64Encoded: String(field)))
    return GeneratedFile(path: path, publicBlob: blob)
}

/// PEM armor around `body`, built here so that no source line contains an armor header.
func armor(_ label: String, _ body: String) -> Data {
    Data("-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----\n".utf8)
}

struct FormatCase: Sendable, CustomTestStringConvertible {
    let name: String
    let arguments: [String]
    var testDescription: String { name }
}

let unencryptedFormats = [
    FormatCase(name: "openssh ed25519", arguments: ["-t", "ed25519"]),
    FormatCase(name: "openssh ecdsa 256", arguments: ["-t", "ecdsa", "-b", "256"]),
    FormatCase(name: "openssh ecdsa 384", arguments: ["-t", "ecdsa", "-b", "384"]),
    FormatCase(name: "openssh ecdsa 521", arguments: ["-t", "ecdsa", "-b", "521"]),
    FormatCase(name: "openssh rsa 3072", arguments: ["-t", "rsa", "-b", "3072"]),
    FormatCase(name: "pkcs1 rsa", arguments: ["-t", "rsa", "-b", "3072", "-m", "PEM"]),
    FormatCase(name: "sec1 ecdsa", arguments: ["-t", "ecdsa", "-b", "256", "-m", "PEM"]),
    FormatCase(name: "pkcs8 rsa", arguments: ["-t", "rsa", "-b", "3072", "-m", "PKCS8"]),
    FormatCase(name: "pkcs8 ecdsa 256", arguments: ["-t", "ecdsa", "-b", "256", "-m", "PKCS8"]),
    FormatCase(name: "pkcs8 ecdsa 384", arguments: ["-t", "ecdsa", "-b", "384", "-m", "PKCS8"]),
    FormatCase(name: "pkcs8 ecdsa 521", arguments: ["-t", "ecdsa", "-b", "521", "-m", "PKCS8"]),
]

@Suite struct Import {
    @Test(arguments: unencryptedFormats)
    func readsEachUnencryptedFormat(format: FormatCase) throws {
        let directory = try TestDirectory()
        let file = try sshKeygen(in: directory, format.arguments, comment: "the comment")
        guard case let .key(key, comment) = try KeyImport.parse(file.contents) else {
            Issue.record("the key was reported as protected")
            return
        }
        #expect(key.publicKey.blob == file.publicBlob)
        if format.name.hasPrefix("openssh") { #expect(comment == "the comment") }
        _ = try SoftwareSigner(key).sign(Data("data".utf8), flags: [])
    }

    @Test func readsAnEd25519PKCS8Key() throws {
        let key = Curve25519.Signing.PrivateKey()
        let der = Data([0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]) + key.rawRepresentation
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        guard case let .key(imported, _) = try KeyImport.parse(armor("PRIVATE KEY", body)) else {
            Issue.record("the key was reported as protected")
            return
        }
        #expect(imported.publicKey.blob == PublicKey.ed25519(key.publicKey.rawRepresentation).blob)
    }

    @Test func readsAPKCS8KeyWithANamedCurve() throws {
        let p384 = P384.Signing.PrivateKey()
        guard case let .key(imported, _) = try KeyImport.parse(Data(p384.pemRepresentation.utf8)) else {
            Issue.record("the key was reported as protected")
            return
        }
        #expect(imported.publicKey.blob == PublicKey.ecdsa(.p384, p384.publicKey.x963Representation).blob)
    }

    @Test(arguments: [
        FormatCase(name: "openssh ed25519", arguments: ["-t", "ed25519"]),
        FormatCase(name: "pkcs1 rsa", arguments: ["-t", "rsa", "-b", "3072", "-m", "PEM"]),
        FormatCase(name: "pkcs8 ecdsa", arguments: ["-t", "ecdsa", "-b", "256", "-m", "PKCS8"]),
    ])
    func reportsAPassphraseProtectedFileAsProtected(format: FormatCase) throws {
        let directory = try TestDirectory()
        let file = try sshKeygen(in: directory, format.arguments, passphrase: "secret")
        #expect(try KeyImport.parse(file.contents) == .protected)
    }

    @Test func refusesRSAUnder2048BitsByName() throws {
        let directory = try TestDirectory()
        let file = try sshKeygen(in: directory, ["-t", "rsa", "-b", "1024"])
        let error = #expect(throws: ImportError.self) { try KeyImport.parse(file.contents) }
        #expect(error?.description.contains("1024") == true)
    }

    @Test func refusesATextFileThatIsNotAKey() {
        #expect(throws: ImportError.self) { try KeyImport.parse(Data("hello".utf8)) }
    }

    @Test func refusesAnotherPEMType() {
        let error = #expect(throws: ImportError.self) { try KeyImport.parse(armor("DSA PRIVATE KEY", "AAAA")) }
        #expect(error?.description.contains("DSA") == true)
    }
}

@Suite struct Generation {
    @Test func ed25519Signs() throws {
        let key = try KeyImport.generate(.ed25519)
        #expect(key.publicKey.keyType == "ssh-ed25519")
        #expect(try SoftwareSigner(key).sign(Data("data".utf8), flags: []).algorithm == "ssh-ed25519")
    }

    @Test(arguments: [(GeneratedKeyType.rsa3072, 3072), (.rsa4096, 4096)])
    func rsaSignsWithTheRequestedBits(type: GeneratedKeyType, bits: Int) throws {
        let key = try KeyImport.generate(type)
        #expect(key.publicKey.rsaBits == bits)
        #expect(try SoftwareSigner(key).sign(Data("data".utf8), flags: .rsaSHA256).algorithm == "rsa-sha2-256")
    }
}

/// Runs the real `ssh-add`, which reads `SSH_ASKPASS` from this process's environment.
@Suite(.serialized) struct SSHAddPath {
    @Test func importsAProtectedFileAndLeavesNoFile() throws {
        let directory = try TestDirectory()
        let file = try sshKeygen(in: directory, ["-t", "ed25519"], passphrase: "secret", comment: "protected key")
        let askpass = directory.path("askpass.sh")
        try "#!/bin/sh\necho secret\n".write(toFile: askpass, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: askpass)
        setenv("SSH_ASKPASS", askpass, 1)
        setenv("SSH_ASKPASS_REQUIRE", "force", 1)
        let before = signdEntries()
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: directory.url.path).sorted()

        let (key, comment) = try KeyImport.importWithSSHAdd(file: file.path)

        #expect(key.publicKey.blob == file.publicBlob)
        #expect(comment == "protected key")
        #expect(signdEntries() == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).sorted() == filesBefore)
    }

    private func signdEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []).filter { $0.hasPrefix("signd-") }.sorted()
    }
}
