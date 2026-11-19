import Foundation
import KeyStore

/// The record types in the `signd` zone, as the production schema names them.
public enum RecordType: String, Codable, Sendable {
    case device = "Device"
    case key = "Key"
    case backup = "Backup"
    case lease = "Lease"

    /// The prefix of every record name of this type.
    public var prefix: String {
        switch self {
        case .device: "device-"
        case .key: "key-"
        case .backup: "backup-"
        case .lease: "lease-"
        }
    }

    /// The type a record name belongs to, or nil for a name with no known prefix.
    public init?(recordName: String) {
        guard let type = [Self.device, .key, .backup, .lease].first(where: { recordName.hasPrefix($0.prefix) }) else { return nil }
        self = type
    }
}

/// A record that a read could not return, by type and name.
/// It carries no payload, so it is safe in the state file.
public struct UnreadableRecord: Codable, Sendable, Equatable {
    public var type: RecordType
    public var name: String

    public init(type: RecordType, name: String) {
        self.type = type
        self.name = name
    }
}

/// One record as signd reads and writes it.
public struct CloudRecord: Sendable, Equatable {
    public var type: RecordType
    public var name: String
    /// The record's one encrypted field.
    public var payload: Data
    /// CloudKit's archived system fields, nil for a record never saved.
    /// They carry the change tag that a save checks.
    public var system: Data?

    public init(type: RecordType, name: String, payload: Data, system: Data? = nil) {
        self.type = type
        self.name = name
        self.payload = payload
        self.system = system
    }
}

/// What a `Device` record shows about one device.
public struct DevicePayload: Codable, Sendable, Equatable {
    public var format = 1
    /// The device's name: a Mac's `LocalHostName`.
    public var name: String
    /// The X9.63 form of the device's key-agreement key.
    public var publicKey: Data
    /// The signd version that wrote the record.
    public var version: String

    public init(name: String, publicKey: Data, version: String) {
        self.name = name
        self.publicKey = publicKey
        self.version = version
    }
}

/// What a `Key` record shows about one shared key.
public struct KeyPayload: Codable, Sendable, Equatable {
    public var format = 1
    public var name: String
    public var comment: String
    public var hosts: [String]
    /// The SSH public blob.
    public var publicKey: Data
    /// The private key sealed to each device, by the device's record name.
    public var sealed: [String: WrappedKey]

    public init(name: String, comment: String, hosts: [String], publicKey: Data, sealed: [String: WrappedKey]) {
        self.name = name
        self.comment = comment
        self.hosts = hosts
        self.publicKey = publicKey
        self.sealed = sealed
    }

    /// The record name for a key name.
    public static func recordName(for name: String) -> String { RecordType.key.prefix + name }
}

/// What the `Backup` record shows: the vault, and the backup token sealed to each device.
public struct BackupPayload: Codable, Sendable, Equatable {
    public var format = 1
    public var vault: String
    /// The token sealed to each device, by the device's record name.
    public var sealed: [String: SealedSecret]

    public init(vault: String, sealed: [String: SealedSecret]) {
        self.vault = vault
        self.sealed = sealed
    }

    /// The one `Backup` record's name.
    public static let recordName = RecordType.backup.prefix + "token"
}

/// Why a payload cannot be read.
public enum PayloadError: Error, Sendable, Equatable, CustomStringConvertible {
    case unreadable
    case format(Int)

    public var description: String {
        switch self {
        case .unreadable: "the record's payload cannot be read"
        case let .format(number): "the record's payload has format \(number), which this signd version does not read"
        }
    }
}

/// The JSON form of the payloads.
public enum Payload {
    private struct Header: Decodable {
        var format: Int
    }

    public static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // Every payload type encodes; a failure would be a programming error.
        return (try? encoder.encode(value)) ?? Data()
    }

    /// Reads a payload of format 1.
    public static func decode<Value: Decodable>(_: Value.Type, from data: Data) throws(PayloadError) -> Value {
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw .unreadable }
        guard header.format == 1 else { throw .format(header.format) }
        guard let value = try? JSONDecoder().decode(Value.self, from: data) else { throw .unreadable }
        return value
    }
}
