import Foundation

/// What signd stores about one `Device` record.
public struct DeviceEntry: Codable, Sendable, Equatable {
    public var name: String
    public var publicKey: Data
    /// CloudKit's system fields, which a save of this device's own record needs.
    public var system: Data?
}

/// What signd stores about one `Key` record; it contains no sealed copy.
public struct KeyEntry: Codable, Sendable, Equatable {
    public var name: String
    public var hosts: [String]
    public var publicKey: Data
    /// The record names of the Macs the key is sealed to.
    public var sealedFor: [String]
}

/// Why this device does not serve a shared key.
public enum SkipKind: String, Codable, Sendable {
    /// No device has sealed the key to this one yet.
    case waiting
    /// A key that is not shared already has the name.
    case nameTaken
    /// A host is not a host pattern.
    case invalidHost
    /// The record cannot be read, or its name and key do not agree.
    case invalidRecord
}

/// A shared key this device does not serve, and why.
public struct SkippedKey: Codable, Sendable, Equatable {
    public var record: String
    public var name: String
    public var kind: SkipKind
    public var reason: String
}

/// How a check ended.
public enum CheckOutcome: String, Codable, Sendable {
    case ok
    case failed
    case throttled
    /// No iCloud account is available.
    case accountUnavailable = "account-unavailable"
    /// The user deleted signd's data in iCloud settings; checks wait for `signd sync`.
    case stopped
    /// This build has no iCloud entitlement.
    case off
}

/// What the agent keeps about syncing, in `sync.json`. It contains no private key and no sealed copy.
public struct SyncState: Codable, Sendable, Equatable {
    public static let currentFormat = 2

    public var format = Self.currentFormat
    /// The iCloud user record the state belongs to.
    public var user: String?
    public var databaseToken: Data?
    public var zoneToken: Data?
    /// Whether the zone and the subscription have been saved.
    public var prepared = false
    /// The user deleted the zone in iCloud settings, so checks wait for `signd sync`.
    public var stopped = false
    /// The `Device` and `Key` records, by record name.
    public var devices: [String: DeviceEntry] = [:]
    public var keys: [String: KeyEntry] = [:]
    public var skipped: [SkippedKey] = []
    public var lastCheck: Date?
    public var lastSuccess: Date?
    public var lastResult: CheckOutcome?
    public var lastMessage: String?
    /// The requests the last check made.
    public var requests = 0
    public var nextAttempt: Date?
    /// Failed checks in a row, which grow the wait.
    public var failures = 0
    public var lastPush: Date?

    public init() {}

    /// `~/Library/Application Support/signd/sync.json`.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/signd/sync.json")
    }

    /// The state in `url`, or an empty one when the file is absent, unreadable or of another format.
    /// An empty state makes the next check read everything.
    public static func load(from url: URL = defaultURL) -> SyncState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(SyncState.self, from: data), state.format == currentFormat else {
            return SyncState()
        }
        return state
    }

    public func save(to url: URL = Self.defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(self), to: url, mode: 0o600)
    }

    /// Forgets the records and tokens, as after a change of account or a deleted zone, and keeps the schedule.
    mutating func forgetRecords() {
        databaseToken = nil
        zoneToken = nil
        prepared = false
        devices = [:]
        keys = [:]
        skipped = []
    }
}

/// What a check did, as `signd sync` reports it.
public struct CheckSummary: Codable, Sendable, Equatable {
    public var outcome: CheckOutcome
    public var message: String?
    public var requests = 0
    public var added: [String] = []
    public var replaced: [String] = []
    public var removed: [String] = []
    /// Keys this device sealed for other devices.
    public var sealed: [String] = []
    public var skipped = 0

    public init(outcome: CheckOutcome, message: String? = nil) {
        self.outcome = outcome
        self.message = message
    }

    public var changed: Bool { !(added.isEmpty && replaced.isEmpty && removed.isEmpty) }
}

/// The result of a request to the agent that changes shared keys or Macs.
public struct SyncResult: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case done
        /// Sync is off in this build or the Mac has no iCloud account, so nothing was shared.
        case off
        case failed
    }

    public var outcome: Outcome
    public var message: String?

    public init(_ outcome: Outcome, _ message: String? = nil) {
        self.outcome = outcome
        self.message = message
    }
}

/// One device, as `signd device list` prints it.
public struct DeviceSummary: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var isThisDevice: Bool
}
