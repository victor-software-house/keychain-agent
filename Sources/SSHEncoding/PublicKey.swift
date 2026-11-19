import CryptoKit
import Foundation

/// An Elliptic Curve Digital Signature Algorithm (ECDSA) curve in SSH, with the key type and curve names it uses.
public enum Curve: String, Sendable, Codable, CaseIterable {
    case p256 = "nistp256"
    case p384 = "nistp384"
    case p521 = "nistp521"

    public var keyType: String { "ecdsa-sha2-\(rawValue)" }
}

/// A public key as SSH encodes it in a key blob.
public enum PublicKey: Sendable, Equatable {
    case ed25519(Data)
    /// The curve and the uncompressed point (X9.63).
    case ecdsa(Curve, Data)
    /// The exponent and the modulus as unsigned big-endian magnitudes.
    case rsa(exponent: Data, modulus: Data)

    /// The key type name, such as `ssh-ed25519`.
    public var keyType: String {
        switch self {
        case .ed25519: "ssh-ed25519"
        case let .ecdsa(curve, _): curve.keyType
        case .rsa: "ssh-rsa"
        }
    }

    /// The SSH public key blob.
    public var blob: Data {
        var blob = Data()
        blob.appendString(keyType)
        switch self {
        case let .ed25519(key):
            blob.appendString(key)
        case let .ecdsa(curve, point):
            blob.appendString(curve.rawValue)
            blob.appendString(point)
        case let .rsa(exponent, modulus):
            blob.appendMPInt(unsigned: exponent)
            blob.appendMPInt(unsigned: modulus)
        }
        return blob
    }

    /// Reads a public key blob; nil for an unsupported type or a malformed blob.
    public init?(blob: Data) {
        var reader = Reader(blob)
        guard let type = reader.text(), let key = Self.read(type: type, from: &reader), reader.isAtEnd else { return nil }
        self = key
    }

    /// Reads the fields that follow a key type name, as a blob or an add-identity message stores them.
    public static func read(type: String, from reader: inout Reader) -> PublicKey? {
        switch type {
        case "ssh-ed25519":
            guard let key = reader.string(), key.count == 32 else { return nil }
            return .ed25519(key)
        case "ssh-rsa":
            guard let exponent = reader.unsignedMPInt(), let modulus = reader.unsignedMPInt() else { return nil }
            return .rsa(exponent: exponent, modulus: modulus)
        default:
            guard let curve = Curve.allCases.first(where: { $0.keyType == type }),
                  reader.text() == curve.rawValue, let point = reader.string() else { return nil }
            return .ecdsa(curve, point)
        }
    }

    /// The OpenSSH one-line form: type, base64 blob and, when given, a comment.
    public func openSSHLine(comment: String = "") -> String {
        let line = "\(keyType) \(blob.base64EncodedString())"
        return comment.isEmpty ? line : "\(line) \(comment)"
    }

    /// The SHA-256 fingerprint as `ssh-keygen -l` prints it.
    public var fingerprint: String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// The Rivest-Shamir-Adleman (RSA) modulus length in bits, or nil for other key types.
    public var rsaBits: Int? {
        guard case let .rsa(_, modulus) = self, let first = modulus.first else { return nil }
        return modulus.count * 8 - first.leadingZeroBitCount
    }
}

/// A signature as SSH encodes it: the algorithm name, then the signature bytes.
public struct Signature: Sendable, Equatable {
    public let algorithm: String
    public let bytes: Data

    public init(algorithm: String, bytes: Data) {
        self.algorithm = algorithm
        self.bytes = bytes
    }

    /// An ECDSA signature from CryptoKit's raw form, `r || s` with fixed-length halves.
    public static func ecdsa(curve: Curve, raw: Data) -> Signature {
        let half = raw.count / 2
        var inner = Data()
        inner.appendMPInt(unsigned: raw.prefix(half))
        inner.appendMPInt(unsigned: raw.suffix(half))
        return Signature(algorithm: curve.keyType, bytes: inner)
    }

    public var blob: Data {
        var blob = Data()
        blob.appendString(algorithm)
        blob.appendString(bytes)
        return blob
    }
}
