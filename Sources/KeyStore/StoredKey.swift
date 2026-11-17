import Foundation
import SSHWire

/// How a stored key holds its private part.
public enum KeyKind: String, Codable, Sendable {
    /// A P-256 key inside the Secure Enclave; `keyData` is its opaque handle.
    case secureEnclave = "secure-enclave"
}

/// One key in the store, as one keychain item holds it.
public struct StoredKey: Codable, Sendable, Equatable {
    /// The item format, so a later release can read an older one.
    public var format = 1
    public var name: String
    public var kind: KeyKind
    public var publicBlob: Data
    public var comment: String
    public var hosts: [String]
    /// Where the key came from: `local` for keys made on this Mac.
    public var source: String
    public var created: Date
    public var keyData: Data

    public init(name: String, kind: KeyKind, publicBlob: Data, comment: String, hosts: [String], source: String = "local", created: Date = Date(), keyData: Data) {
        self.name = name
        self.kind = kind
        self.publicBlob = publicBlob
        self.comment = comment
        self.hosts = hosts
        self.source = source
        self.created = created
        self.keyData = keyData
    }

    public var publicKey: PublicKey? { PublicKey(blob: publicBlob) }

    /// The comment ssh-add shows: the comment, or the name when the comment is empty.
    public var displayComment: String { comment.isEmpty ? name : comment }

    /// Names are what commands use, so they stay plain: letters, digits, `-`, `_` and `.`.
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
public protocol KeyStore: Sendable {
    func list() throws(StoreError) -> [StoredKey]
    func add(_ key: StoredKey) throws(StoreError)
    func delete(name: String) throws(StoreError)
}
