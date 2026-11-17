import AgentProtocol
import Crypto
import CryptoExtras
import Foundation
import SSHWire

/// Why a signature failed.
public enum SignError: Error, Sendable {
    case invalidKey(String)
    case failed(String)
}

/// Something that signs for one key.
public protocol Signer: Sendable {
    var publicKey: PublicKey { get }
    func sign(_ data: Data, flags: SignFlags) throws(SignError) -> Signature
}

/// Signs with a Secure Enclave P-256 key, inside the Secure Enclave.
public struct SecureEnclaveSigner: Signer {
    private let key: SecureEnclave.P256.Signing.PrivateKey
    public let publicKey: PublicKey

    public init(handle: Data) throws(SignError) {
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: handle)
        } catch {
            throw .invalidKey("Secure Enclave key: \(error)")
        }
        publicKey = .ecdsa(.p256, key.publicKey.x963Representation)
    }

    public func sign(_ data: Data, flags _: SignFlags) throws(SignError) -> Signature {
        do {
            return .ecdsa(curve: .p256, raw: try key.signature(for: data).rawRepresentation)
        } catch {
            throw .failed("Secure Enclave: \(error)")
        }
    }
}

/// Signs with a private key held in memory.
public struct SoftwareSigner: Signer {
    private enum Key {
        case ed25519(Curve25519.Signing.PrivateKey)
        case p256(P256.Signing.PrivateKey)
        case p384(P384.Signing.PrivateKey)
        case p521(P521.Signing.PrivateKey)
        case rsa(_RSA.Signing.PrivateKey)
    }

    private let key: Key
    public let publicKey: PublicKey

    public init(_ privateKey: PrivateKey) throws(SignError) {
        publicKey = privateKey.publicKey
        do {
            switch privateKey {
            case let .ed25519(seed, expected):
                let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
                guard key.publicKey.rawRepresentation == expected else { throw SignError.invalidKey("Ed25519 seed and public key differ") }
                self.key = .ed25519(key)
            case let .ecdsa(curve, point, scalar):
                self.key = try Self.ecdsa(curve, scalar: scalar)
                guard Self.point(of: self.key) == point else { throw SignError.invalidKey("ECDSA scalar and point differ") }
            case let .rsa(n, e, d, _, p, q):
                guard let bits = publicKey.rsaBits, bits >= 2048, bits <= 8192 else {
                    throw SignError.invalidKey("RSA \(publicKey.rsaBits ?? 0) bits; signd serves 2048 to 8192")
                }
                key = .rsa(try _RSA.Signing.PrivateKey(n: n, e: e, d: d, p: p, q: q))
            }
        } catch let error as SignError {
            throw error
        } catch {
            throw .invalidKey("\(error)")
        }
    }

    private static func ecdsa(_ curve: Curve, scalar: Data) throws -> Key {
        // CryptoKit wants the scalar at the curve's full length.
        func padded(_ length: Int) -> Data { Data(repeating: 0, count: max(0, length - scalar.count)) + scalar }
        switch curve {
        case .p256: return .p256(try P256.Signing.PrivateKey(rawRepresentation: padded(32)))
        case .p384: return .p384(try P384.Signing.PrivateKey(rawRepresentation: padded(48)))
        case .p521: return .p521(try P521.Signing.PrivateKey(rawRepresentation: padded(66)))
        }
    }

    private static func point(of key: Key) -> Data? {
        switch key {
        case let .p256(key): key.publicKey.x963Representation
        case let .p384(key): key.publicKey.x963Representation
        case let .p521(key): key.publicKey.x963Representation
        case .ed25519, .rsa: nil
        }
    }

    public func sign(_ data: Data, flags: SignFlags) throws(SignError) -> Signature {
        do {
            switch key {
            case let .ed25519(key):
                return Signature(algorithm: "ssh-ed25519", bytes: try key.signature(for: data))
            case let .p256(key):
                return .ecdsa(curve: .p256, raw: try key.signature(for: data).rawRepresentation)
            case let .p384(key):
                return .ecdsa(curve: .p384, raw: try key.signature(for: data).rawRepresentation)
            case let .p521(key):
                return .ecdsa(curve: .p521, raw: try key.signature(for: data).rawRepresentation)
            case let .rsa(key):
                let algorithm = RSAAlgorithm(flags: flags)
                let signature = switch algorithm {
                case .sha512: try key.signature(for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5)
                case .sha256: try key.signature(for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5)
                case .sha1: try key.signature(for: Insecure.SHA1.hash(data: data), padding: .insecurePKCS1v1_5)
                }
                return Signature(algorithm: algorithm.rawValue, bytes: signature.rawRepresentation)
            }
        } catch {
            throw .failed("\(error)")
        }
    }
}
