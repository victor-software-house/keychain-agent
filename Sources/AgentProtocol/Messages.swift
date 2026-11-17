import Foundation

// The messages of the SSH agent protocol that keychain-agent speaks:
// https://datatracker.ietf.org/doc/draft-ietf-sshm-ssh-agent/

/// The message numbers keychain-agent reads or writes.
public enum MessageType: UInt8, Sendable {
    case failure = 5
    case requestIdentities = 11
    case identitiesAnswer = 12
    case signRequest = 13
    case signResponse = 14
}

/// The flags of a sign request that pick the RSA signature hash.
public struct SignFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let rsaSHA256 = SignFlags(rawValue: 2)
    public static let rsaSHA512 = SignFlags(rawValue: 4)
}

/// An RSA signature algorithm, named as SSH names it.
public enum SignatureAlgorithm: String, Sendable, Equatable {
    case rsaSHA512 = "rsa-sha2-512"
    case rsaSHA256 = "rsa-sha2-256"
    case rsaSHA1 = "ssh-rsa"

    /// The algorithm a sign request asks for; SHA-512 wins when both flags are set.
    public init(flags: SignFlags) {
        if flags.contains(.rsaSHA512) {
            self = .rsaSHA512
        } else if flags.contains(.rsaSHA256) {
            self = .rsaSHA256
        } else {
            self = .rsaSHA1
        }
    }
}

/// A request from a client, read from one message body.
public enum Request: Sendable, Equatable {
    case identities
    case sign(keyBlob: Data, data: Data, flags: SignFlags)
    /// A message type keychain-agent does not serve, such as an extension.
    case unsupported(UInt8)
    /// An empty body, or a sign request whose fields are cut short.
    case malformed

    public init(body: Data) {
        guard let type = body.first else {
            self = .malformed
            return
        }
        switch MessageType(rawValue: type) {
        case .requestIdentities:
            self = .identities
        case .signRequest:
            var reader = Reader(body.dropFirst())
            guard let keyBlob = reader.string(), let data = reader.string(), let flags = reader.uint32() else {
                self = .malformed
                return
            }
            self = .sign(keyBlob: keyBlob, data: data, flags: SignFlags(rawValue: flags))
        case .failure, .identitiesAnswer, .signResponse, nil:
            self = .unsupported(type)
        }
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
    case identities([Identity])
    case signature(algorithm: SignatureAlgorithm, bytes: Data)

    /// The message body, without the length that frames it.
    public var body: Data {
        var body = Data()
        switch self {
        case .failure:
            body.append(MessageType.failure.rawValue)
        case let .identities(identities):
            body.append(MessageType.identitiesAnswer.rawValue)
            body.appendUInt32(UInt32(identities.count))
            for identity in identities {
                body.appendString(identity.blob)
                body.appendString(Data(identity.comment.utf8))
            }
        case let .signature(algorithm, bytes):
            var signature = Data()
            signature.appendString(Data(algorithm.rawValue.utf8))
            signature.appendString(bytes)
            body.append(MessageType.signResponse.rawValue)
            body.appendString(signature)
        }
        return body
    }
}

/// The length prefix that frames every message.
public enum Frame {
    /// The longest message body keychain-agent reads; OpenSSH's own agent uses the same bound.
    public static let maximumLength = 256 * 1024

    /// The body length a 4-byte header announces, or nil when it is zero or over the bound.
    public static func length(header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let length = Int(header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard length > 0, length <= maximumLength else { return nil }
        return length
    }

    /// `body` with its length in front.
    public static func encode(_ body: Data) -> Data {
        var message = Data()
        message.appendString(body)
        return message
    }
}
