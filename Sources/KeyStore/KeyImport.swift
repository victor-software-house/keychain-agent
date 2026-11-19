import Crypto
import CryptoExtras
import Foundation
import SSHEncoding
import SwiftASN1

/// A private key file read for import.
public enum ImportedKey: Sendable, Equatable {
    case key(PrivateKey, comment: String)
    /// The file is encrypted with a passphrase.
    case encrypted
}

/// The key types `key create --type` generates besides Secure Enclave keys.
public enum GeneratedKeyType: String, Sendable, CaseIterable {
    case ed25519
    case rsa3072
    case rsa4096
}

/// Why an import or a generation failed.
public enum ImportError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupported(String)
    case unreadable(String)
    case encryptedKeyOnStdin
    case sshAdd(String)

    public var description: String {
        switch self {
        case let .unsupported(reason): "unsupported key: \(reason)"
        case let .unreadable(reason): "cannot read the key: \(reason)"
        case .encryptedKeyOnStdin: "an encrypted key must be given as a file, so ssh-add can ask for its passphrase"
        case let .sshAdd(reason): "ssh-add: \(reason)"
        }
    }
}

/// Reads private key files and generates keys, as the numbers a `PrivateKey` stores.
public enum KeyImport {
    /// Reads an OpenSSH, `PKCS#1`, `PKCS#8` or SEC1 private key file, as PEM text.
    public static func parse(_ data: Data) throws(ImportError) -> ImportedKey {
        guard let text = String(data: data, encoding: .utf8), let label = pemLabel(text) else {
            throw .unreadable("not a PEM private key file")
        }
        let imported: ImportedKey
        switch label {
        case "OPENSSH PRIVATE KEY":
            imported = try openSSH(text)
        case "RSA PRIVATE KEY":
            imported = text.contains("Proc-Type: 4,ENCRYPTED") ? .encrypted : .key(try rsa(pem: text), comment: "")
        case "PRIVATE KEY":
            imported = .key(try pkcs8(pem: text), comment: "")
        case "EC PRIVATE KEY":
            let der = try wrap("PEM") { try PEMDocument(pemString: text).derBytes }
            imported = .key(try ecdsa(sec1: der, fallback: nil), comment: "")
        case "ENCRYPTED PRIVATE KEY":
            imported = .encrypted
        default:
            throw .unsupported("\(label) files")
        }
        if case let .key(key, _) = imported { try validate(key) }
        return imported
    }

    /// Refuses a key signd cannot serve, such as Rivest-Shamir-Adleman (RSA) under 2048 bits, with the reason.
    public static func validate(_ key: PrivateKey) throws(ImportError) {
        do {
            _ = try SoftwareSigner(key)
        } catch {
            throw .unsupported(error.reason)
        }
    }

    public static func generate(_ type: GeneratedKeyType) throws(ImportError) -> PrivateKey {
        switch type {
        case .ed25519:
            let key = Curve25519.Signing.PrivateKey()
            return .ed25519(seed: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation)
        case .rsa3072:
            return try rsaNumbers(of: try wrap("RSA generation") { try _RSA.Signing.PrivateKey(keySize: .bits3072) })
        case .rsa4096:
            return try rsaNumbers(of: try wrap("RSA generation") { try _RSA.Signing.PrivateKey(keySize: .bits4096) })
        }
    }

    // MARK: Formats

    private static func pemLabel(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("-----BEGIN "), line.hasSuffix("-----"), line.count > 16 {
                return String(line.dropFirst(11).dropLast(5))
            }
        }
        return nil
    }

    private static func wrap<T>(_ what: String, _ body: () throws -> T) throws(ImportError) -> T {
        do {
            return try body()
        } catch {
            throw .unreadable("\(what): \(error)")
        }
    }

    private static func openSSH(_ text: String) throws(ImportError) -> ImportedKey {
        do throws(OpenSSHKeyFile.Failure) {
            switch try OpenSSHKeyFile.parse(text) {
            case let .key(key, comment): return .key(key, comment: comment)
            case .encrypted: return .encrypted
            }
        } catch {
            switch error {
            case .malformed: throw .unreadable("malformed OpenSSH private key")
            case let .unsupportedType(type): throw .unsupported("\(type) keys")
            }
        }
    }

    private static func rsa(pem: String) throws(ImportError) -> PrivateKey {
        let der = try wrap("PEM") { try PEMDocument(pemString: pem).derBytes }
        // The unsafe initializer accepts 1024 bits, so `validate` can refuse the key by name.
        let key = try wrap("RSA key") { try _RSA.Signing.PrivateKey(unsafeDERRepresentation: der) }
        return try rsaNumbers(of: key)
    }

    /// Reads `ECPrivateKey ::= SEQUENCE { version, privateKey, [0] parameters, [1] publicKey }` (SEC1);
    /// the curve comes from its parameters, or from `fallback`, the `PKCS#8` algorithm parameters.
    private static func ecdsa(sec1 der: [UInt8], fallback: Curve?) throws(ImportError) -> PrivateKey {
        let (scalar, named) = try wrap("EC key") {
            try DER.sequence(try DER.parse(der), identifier: .sequence) { nodes in
                _ = try Int(derEncoded: &nodes)
                let scalar = Data(try ASN1OctetString(derEncoded: &nodes).bytes)
                let named = try DER.optionalExplicitlyTagged(&nodes, tagNumber: 0, tagClass: .contextSpecific) { curve(of: $0) }
                while nodes.next() != nil {}
                return (scalar, named ?? nil)
            }
        }
        guard let curve = named ?? fallback else { throw .unsupported("EC keys other than P-256, P-384 and P-521") }
        func padded(_ length: Int) -> Data { Data(repeating: 0, count: max(0, length - scalar.count)) + scalar }
        switch curve {
        case .p256:
            let key = try wrap("P-256 key") { try P256.Signing.PrivateKey(rawRepresentation: padded(32)) }
            return .ecdsa(.p256, point: key.publicKey.x963Representation, scalar: key.rawRepresentation)
        case .p384:
            let key = try wrap("P-384 key") { try P384.Signing.PrivateKey(rawRepresentation: padded(48)) }
            return .ecdsa(.p384, point: key.publicKey.x963Representation, scalar: key.rawRepresentation)
        case .p521:
            let key = try wrap("P-521 key") { try P521.Signing.PrivateKey(rawRepresentation: padded(66)) }
            return .ecdsa(.p521, point: key.publicKey.x963Representation, scalar: key.rawRepresentation)
        }
    }

    /// The curve an `ECParameters` node selects: an object identifier (OID), or the explicit parameters
    /// that macOS's ssh-keygen writes.
    /// Their field prime tells them apart.
    private static func curve(of parameters: ASN1Node) -> Curve? {
        if let oid = try? ASN1ObjectIdentifier(derEncoded: parameters) {
            return switch oid {
            case p256Curve: .p256
            case p384Curve: .p384
            case p521Curve: .p521
            default: nil
            }
        }
        let prime = try? DER.sequence(parameters, identifier: .sequence) { nodes in
            _ = try Int(derEncoded: &nodes)
            guard let field = nodes.next() else { throw ASN1Error.invalidASN1Object(reason: "no field") }
            let prime = try DER.sequence(field, identifier: .sequence) { inner in
                _ = try ASN1ObjectIdentifier(derEncoded: &inner)
                return Data(try ArraySlice<UInt8>(derEncoded: &inner).drop { $0 == 0 })
            }
            while nodes.next() != nil {}
            return prime
        }
        return switch prime {
        case primeP256: .p256
        case primeP384: .p384
        case primeP521: .p521
        default: nil
        }
    }

    private static let primeP256 = Data([0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 1] + [UInt8](repeating: 0, count: 12) + [UInt8](repeating: 0xFF, count: 12))
    private static let primeP384 = Data([UInt8](repeating: 0xFF, count: 31) + [0xFE] + [UInt8](repeating: 0xFF, count: 4) + [UInt8](repeating: 0, count: 8) + [UInt8](repeating: 0xFF, count: 4))
    private static let primeP521 = Data([0x01] + [UInt8](repeating: 0xFF, count: 65))

    private static let rsaAlgorithm: ASN1ObjectIdentifier = [1, 2, 840, 113_549, 1, 1, 1]
    private static let ecAlgorithm: ASN1ObjectIdentifier = [1, 2, 840, 10045, 2, 1]
    private static let ed25519Algorithm: ASN1ObjectIdentifier = [1, 3, 101, 112]
    private static let p256Curve: ASN1ObjectIdentifier = [1, 2, 840, 10045, 3, 1, 7]
    private static let p384Curve: ASN1ObjectIdentifier = [1, 3, 132, 0, 34]
    private static let p521Curve: ASN1ObjectIdentifier = [1, 3, 132, 0, 35]

    /// The parts of a `PKCS#8` `PrivateKeyInfo` that decide how to read it.
    private struct PrivateKeyInfo {
        let algorithm: ASN1ObjectIdentifier
        /// The curve that an Elliptic Curve (EC) key's algorithm parameters select.
        let curve: Curve?
        let privateKey: ASN1OctetString

        init(der: [UInt8]) throws {
            let node = try DER.parse(der)
            let parsed = try DER.sequence(node, identifier: .sequence) { nodes in
                _ = try Int(derEncoded: &nodes)
                guard let algorithmNode = nodes.next() else { throw ASN1Error.invalidASN1Object(reason: "no algorithm") }
                let algorithm = try DER.sequence(algorithmNode, identifier: .sequence) { inner in
                    let oid = try ASN1ObjectIdentifier(derEncoded: &inner)
                    let curve = inner.next().flatMap { KeyImport.curve(of: $0) }
                    while inner.next() != nil {}
                    return (oid, curve)
                }
                return (algorithm, try ASN1OctetString(derEncoded: &nodes))
            }
            algorithm = parsed.0.0
            curve = parsed.0.1
            privateKey = parsed.1
        }
    }

    private static func pkcs8(pem: String) throws(ImportError) -> PrivateKey {
        let info = try wrap("PKCS#8 key") { try PrivateKeyInfo(der: try PEMDocument(pemString: pem).derBytes) }
        switch info.algorithm {
        case rsaAlgorithm: return try rsa(pem: pem)
        case ecAlgorithm: return try ecdsa(sec1: Array(info.privateKey.bytes), fallback: info.curve)
        case ed25519Algorithm:
            // The private key contains a second octet string, which contains the 32-byte seed.
            let seed = try wrap("Ed25519 key") { try ASN1OctetString(derEncoded: try DER.parse(Array(info.privateKey.bytes))).bytes }
            let key = try wrap("Ed25519 key") { try Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed)) }
            return .ed25519(seed: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation)
        default:
            throw .unsupported("PKCS#8 keys of algorithm \(info.algorithm)")
        }
    }

    /// Reads `RSAPrivateKey ::= SEQUENCE { version, n, e, d, p, q, dp, dq, qinv }` from a key's Distinguished Encoding Rules (DER) bytes,
    /// taking the `PKCS#1` form or unwrapping a `PKCS#8` one.
    private static func rsaNumbers(of key: _RSA.Signing.PrivateKey) throws(ImportError) -> PrivateKey {
        do {
            return try rsaNumbers(der: Array(key.derRepresentation))
        } catch {
            throw .unreadable("RSA numbers: \(error)")
        }
    }

    private static func rsaNumbers(der: [UInt8]) throws -> PrivateKey {
        let node = try DER.parse(der)
        return try DER.sequence(node, identifier: .sequence) { nodes in
            _ = try Int(derEncoded: &nodes)
            guard let next = nodes.next() else { throw ASN1Error.invalidASN1Object(reason: "RSA key ends after its version") }
            if next.identifier == .sequence {
                // `PKCS#8`: the algorithm identifier, then an octet string that contains the `PKCS#1` key.
                let inner = try ASN1OctetString(derEncoded: &nodes)
                return try rsaNumbers(der: Array(inner.bytes))
            }
            func number(_ node: ASN1Node) throws -> Data {
                Data(try ArraySlice<UInt8>(derEncoded: node).drop { $0 == 0 })
            }
            let n = try number(next)
            guard let e = try nodes.next().map(number), let d = try nodes.next().map(number),
                  let p = try nodes.next().map(number), let q = try nodes.next().map(number),
                  nodes.next() != nil, nodes.next() != nil, let iqmp = try nodes.next().map(number) else {
                throw ASN1Error.invalidASN1Object(reason: "RSA key has too few numbers")
            }
            return .rsa(n: n, e: e, d: d, iqmp: iqmp, p: p, q: q)
        }
    }
}

extension SignError {
    fileprivate var reason: String {
        switch self {
        case let .invalidKey(reason), let .failed(reason): reason
        }
    }
}
