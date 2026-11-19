import Foundation
import SSHEncoding

/// How a stored key keeps its private part.
public enum KeyKind: String, Codable, Sendable {
    /// A P-256 key inside the Secure Enclave; `keyData` is its opaque handle.
    case secureEnclave = "secure-enclave"
    /// An Ed25519, Elliptic Curve Digital Signature Algorithm (ECDSA) or Rivest-Shamir-Adleman (RSA) key.
    /// It is sealed to a Secure Enclave key-agreement key; `keyData` is that key's opaque handle.
    case wrapped = "wrapped"
}

/// One key in the store, as one keychain item stores it.
public struct StoredKey: Codable, Sendable, Equatable {
    /// The item format, so a later release can read an older one.
    public var format = 1
    public var name: String
    public var kind: KeyKind
    public var publicBlob: Data
    public var comment: String
    public var hosts: [String]
    /// Where the key came from: `local` for a key made on this Mac, `import` for an imported one, `icloud` for one another device shared.
    /// Sharing a key keeps its source, so a key this Mac made stays this Mac's own when the iCloud data goes.
    public var source: String
    public var created: Date
    public var keyData: Data
    /// The sealed private key of a wrapped key; nil for a Secure Enclave key.
    public var wrapped: WrappedKey?
    /// The `Key` record of a shared key; nil for a key that is not shared.
    public var recordName: String?

    /// The `source` of a key another device shared with this one.
    public static let receivedSource = "icloud"

    /// Whether a `Key` record shares the key between devices.
    public var isShared: Bool { recordName != nil }

    /// Whether another device shared the key with this one, so this Mac has no copy of its own.
    public var isReceived: Bool { source == Self.receivedSource }

    public init(
        name: String, kind: KeyKind, publicBlob: Data, comment: String, hosts: [String], source: String = "local", created: Date = Date(),
        keyData: Data, wrapped: WrappedKey? = nil, recordName: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.publicBlob = publicBlob
        self.comment = comment
        self.hosts = hosts
        self.source = source
        self.created = created
        self.keyData = keyData
        self.wrapped = wrapped
        self.recordName = recordName
    }

    public var publicKey: PublicKey? { PublicKey(blob: publicBlob) }

    /// The comment ssh-add shows: the comment, or the name when the comment is empty.
    public var displayComment: String { comment.isEmpty ? name : comment }

    /// Commands use names, so a valid name has only letters, digits, `-`, `_` and `.`.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// Host patterns go into the SSH configuration, so they hold only pattern characters.
    public static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_*?".contains($0)) }
    }
}

/// Why a store operation failed.
public enum StoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case duplicate(String)
    case notFound(String)
    case invalidName(String)
    case invalidHost(String)
    /// The keychain is not readable yet, as before the first unlock after boot.
    case locked
    case keychain(OSStatus)
    case corrupt(String)
    case secureEnclave(String)

    public var description: String {
        switch self {
        case let .duplicate(name): "a key named \(name) exists"
        case let .notFound(name): "no key named \(name)"
        case let .invalidName(name): "invalid key name \(name): use letters, digits, '-', '_' and '.'"
        case let .invalidHost(host): "invalid host pattern \(host): use letters, digits, '.', '-', '_', '*' and '?'"
        case .locked: "the keychain is locked until the Mac is unlocked once after boot"
        case let .keychain(status): "keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        case let .corrupt(name): "the item for \(name) cannot be read"
        case let .secureEnclave(reason): "Secure Enclave: \(reason)"
        }
    }
}

/// Where stored keys live.
public protocol KeyStorage: Sendable {
    func list() throws(StoreError) -> [StoredKey]
    func add(_ key: StoredKey) throws(StoreError)
    /// Replaces the key of the same name in one keychain write.
    func replace(_ key: StoredKey) throws(StoreError)
    func delete(name: String) throws(StoreError)
}
