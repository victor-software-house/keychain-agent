import Foundation
import SSHWire

// The SSH agent messages signd reads and writes (RFC 9987).

/// Message numbers.
public enum MessageType: UInt8, Sendable {
    case failure = 5
    case success = 6
    case requestIdentities = 11
    case identitiesAnswer = 12
    case signRequest = 13
    case signResponse = 14
    case addIdentity = 17
    case removeIdentity = 18
    case removeAllIdentities = 19
    case lock = 22
    case unlock = 23
    case addIdentityConstrained = 25
    case `extension` = 27
    case extensionFailure = 28
    case extensionResponse = 29
}

/// The flags of a sign request that pick the Rivest-Shamir-Adleman (RSA) signature hash.
public struct SignFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let rsaSHA256 = SignFlags(rawValue: 2)
    public static let rsaSHA512 = SignFlags(rawValue: 4)
}

/// An RSA signature algorithm, as SSH names it.
public enum RSAAlgorithm: String, Sendable, Equatable {
    case sha512 = "rsa-sha2-512"
    case sha256 = "rsa-sha2-256"
    case sha1 = "ssh-rsa"

    /// The algorithm a sign request selects; SHA-512 wins when both flags are set.
    public init(flags: SignFlags) {
        if flags.contains(.rsaSHA512) {
            self = .sha512
        } else if flags.contains(.rsaSHA256) {
            self = .sha256
        } else {
            self = .sha1
        }
    }
}

/// The constraints of an add-identity request that signd honours.
public struct Constraints: Sendable, Equatable {
    public var lifetime: UInt32?
    public var confirm = false
    /// Extension constraints by name; signd refuses a key that carries any.
    public var extensions: [String] = []

    public init(lifetime: UInt32? = nil, confirm: Bool = false, extensions: [String] = []) {
        self.lifetime = lifetime
        self.confirm = confirm
        self.extensions = extensions
    }
}

/// The extensions signd answers.
public enum Extension {
    public static let query = "query"
    public static let sessionBind = "session-bind@openssh.com"
    public static let supported = [query, sessionBind]
}

/// A request from a client, read from one message body.
public enum Request: Sendable, Equatable {
    case identities
    case sign(keyBlob: Data, data: Data, flags: SignFlags)
    case add(key: PrivateKey, comment: String, constraints: Constraints)
    case remove(keyBlob: Data)
    case removeAll
    case `extension`(name: String, contents: Data)
    /// A message type signd does not serve, such as lock.
    case unsupported(UInt8)
    /// An empty body, or fields that are cut short or invalid.
    case malformed

    public init(body: Data) {
        guard let type = body.first else {
            self = .malformed
            return
        }
        var reader = Reader(body.dropFirst())
        self = switch MessageType(rawValue: type) {
        case .requestIdentities: .identities
        case .signRequest: Self.sign(&reader)
        case .addIdentity: Self.add(&reader, constrained: false)
        case .addIdentityConstrained: Self.add(&reader, constrained: true)
        case .removeIdentity: reader.string().map { .remove(keyBlob: $0) } ?? .malformed
        case .removeAllIdentities: .removeAll
        case .extension: reader.text().map { .extension(name: $0, contents: reader.rest()) } ?? .malformed
        default: .unsupported(type)
        }
    }

    private static func sign(_ reader: inout Reader) -> Request {
        guard let keyBlob = reader.string(), let data = reader.string(), let flags = reader.uint32() else { return .malformed }
        return .sign(keyBlob: keyBlob, data: data, flags: SignFlags(rawValue: flags))
    }

    private static func add(_ reader: inout Reader, constrained: Bool) -> Request {
        guard let key = PrivateKey.read(from: &reader), let comment = reader.text() else { return .malformed }
        var constraints = Constraints()
        while constrained, !reader.isAtEnd {
            switch reader.byte() {
            case 1:
                guard let seconds = reader.uint32() else { return .malformed }
                constraints.lifetime = seconds
            case 2:
                constraints.confirm = true
            case 255:
                // An extension constraint's details have no common framing, so parsing stops here.
                guard let name = reader.text() else { return .malformed }
                constraints.extensions.append(name)
                _ = reader.rest()
            default:
                return .malformed
            }
        }
        return reader.isAtEnd ? .add(key: key, comment: comment, constraints: constraints) : .malformed
    }
}

/// A key the agent lists: its public key blob and its comment.
public struct Identity: Sendable, Equatable {
    public let blob: Data
    public let comment: String

    public init(blob: Data, comment: String) {
        self.blob = blob
        self.comment = comment
    }
}

/// A reply to a client.
public enum Response: Sendable, Equatable {
    case failure
    case success
    case identities([Identity])
    case signature(Signature)
    case extensionResponse(name: String, contents: Data)

    /// The message body, without the length that frames it.
    public var body: Data {
        var body = Data()
        switch self {
        case .failure:
            body.append(MessageType.failure.rawValue)
        case .success:
            body.append(MessageType.success.rawValue)
        case let .identities(identities):
            body.append(MessageType.identitiesAnswer.rawValue)
            body.appendUInt32(UInt32(identities.count))
            for identity in identities {
                body.appendString(identity.blob)
                body.appendString(identity.comment)
            }
        case let .signature(signature):
            body.append(MessageType.signResponse.rawValue)
            body.appendString(signature.blob)
        case let .extensionResponse(name, contents):
            body.append(MessageType.extensionResponse.rawValue)
            body.appendString(name)
            body.append(contents)
        }
        return body
    }

    /// The reply to the `query` extension: the names of the supported extensions.
    public static var query: Response {
        var contents = Data()
        for name in Extension.supported {
            contents.appendString(name)
        }
        return .extensionResponse(name: Extension.query, contents: contents)
    }
}

/// The length prefix that frames every message.
public enum Frame {
    /// The longest message body signd reads; OpenSSH's own agent uses the same bound.
    public static let maximumLength = 256 * 1024
}
