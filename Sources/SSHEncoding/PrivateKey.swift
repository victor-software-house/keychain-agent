import Foundation

/// The parts of a private key, in the layout that an add-identity message and an unencrypted
/// `openssh-key-v1` file share.
/// They are the key type name, then type-specific fields.
public enum PrivateKey: Sendable, Equatable {
    /// The 32-byte seed and the 32-byte public key.
    case ed25519(seed: Data, publicKey: Data)
    /// The curve, the uncompressed public point and the private scalar.
    case ecdsa(Curve, point: Data, scalar: Data)
    /// The Rivest-Shamir-Adleman (RSA) numbers as unsigned big-endian magnitudes.
    case rsa(n: Data, e: Data, d: Data, iqmp: Data, p: Data, q: Data)

    public var publicKey: PublicKey {
        switch self {
        case let .ed25519(_, key): .ed25519(key)
        case let .ecdsa(curve, point, _): .ecdsa(curve, point)
        case let .rsa(n, e, _, _, _, _): .rsa(exponent: e, modulus: n)
        }
    }

    /// Reads a key type name and its fields; nil for an unsupported type or malformed fields.
    public static func read(from reader: inout Reader) -> PrivateKey? {
        guard let type = reader.readText() else { return nil }
        switch type {
        case "ssh-ed25519":
            // The private field is the seed followed by the public key, 64 bytes in all.
            guard let publicKey = reader.readString(), publicKey.count == 32,
                  let secret = reader.readString(), secret.count == 64, secret.suffix(32) == publicKey else { return nil }
            return .ed25519(seed: Data(secret.prefix(32)), publicKey: publicKey)
        case "ssh-rsa":
            guard let n = reader.readUnsignedMPInt(), let e = reader.readUnsignedMPInt(), let d = reader.readUnsignedMPInt(),
                  let iqmp = reader.readUnsignedMPInt(), let p = reader.readUnsignedMPInt(), let q = reader.readUnsignedMPInt() else { return nil }
            return .rsa(n: n, e: e, d: d, iqmp: iqmp, p: p, q: q)
        default:
            guard let curve = Curve.allCases.first(where: { $0.keyType == type }), reader.readText() == curve.rawValue,
                  let point = reader.readString(), let scalar = reader.readUnsignedMPInt() else { return nil }
            return .ecdsa(curve, point: point, scalar: scalar)
        }
    }

    /// Writes the key type name and its fields in the shared layout.
    public func write(to data: inout Data) {
        data.appendString(publicKey.keyType)
        switch self {
        case let .ed25519(seed, publicKey):
            data.appendString(publicKey)
            data.appendString(seed + publicKey)
        case let .ecdsa(curve, point, scalar):
            data.appendString(curve.rawValue)
            data.appendString(point)
            data.appendMPInt(unsigned: scalar)
        case let .rsa(n, e, d, iqmp, p, q):
            for number in [n, e, d, iqmp, p, q] {
                data.appendMPInt(unsigned: number)
            }
        }
    }
}
