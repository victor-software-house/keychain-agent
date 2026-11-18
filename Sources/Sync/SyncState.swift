import Foundation

/// Why a check left an item out.
public enum SkipKind: String, Codable, Sendable {
    /// The item's `macs` field does not name this Mac; `signd status` does not report it.
    case otherMac
    case invalidName
    case invalidHost
    case invalidKey
    case nameTaken
    case invalidNote
}

/// An item a check read and did not serve.
public struct SkippedItem: Codable, Sendable, Equatable {
    public var vaultID: String
    public var itemID: String
    public var title: String
    /// The item's `updatedAt` when it was read, so an unchanged item is not read again.
    public var updated: Date
    public var kind: SkipKind
    public var reason: String
    /// The key name a `nameTaken` item wanted, so a later check can tell, with no request, whether another key still holds it.
    public var name: String?
    /// The signd version whose client could not read the item's reply; a later version reads the item again.
    public var undecodedBy: String?

    public var isReported: Bool { kind != .otherMac }
}

/// How a check ended.
public enum CheckOutcome: String, Codable, Sendable {
    case ok
    case failed
    case rateLimited = "rate-limited"
    case tokenRefused = "token-refused"
    case notSignedIn = "not-signed-in"
}

/// The `signd` note a check last read.
public struct NoteRef: Codable, Sendable, Equatable {
    public var vaultID: String
    public var itemID: String
    public var updated: Date
}

/// What the agent keeps about syncing, in `sync.json`. It holds no secret.
public struct SyncState: Codable, Sendable, Equatable {
    public var format = 1
    /// Each vault's content version at the last successful check.
    public var vaultVersions: [String: UInt32] = [:]
    public var note: NoteRef?
    /// The settings the `signd` note sets for every Mac.
    public var fleet: [String: String] = [:]
    public var skipped: [SkippedItem] = []
    public var lastCheck: Date?
    public var lastSuccess: Date?
    public var lastResult: CheckOutcome?
    public var lastMessage: String?
    public var requests = 0
    public var fetched = 0
    public var nextAttempt: Date?
    /// Failed checks in a row, which grow the wait.
    public var failures = 0
    /// Rate-limited checks in a row, which grow the wait.
    public var rateLimits = 0

    public init() {}

    /// `~/Library/Application Support/signd/sync.json`.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/signd/sync.json")
    }

    /// The state in `url`; an empty one when the file is absent or unreadable, which makes the next check read everything.
    public static func load(from url: URL = defaultURL) -> SyncState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(SyncState.self, from: data) else { return SyncState() }
        return state
    }

    public func save(to url: URL = Self.defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(self), to: url, mode: 0o600)
    }

    /// Forgets the state, as a new token or a logout does.
    public static func remove(at url: URL = defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// What a check did, as `signd sync` reports it.
public struct CheckSummary: Codable, Sendable, Equatable {
    public var outcome: CheckOutcome
    public var message: String?
    public var requests = 0
    public var fetched = 0
    public var added: [String] = []
    public var replaced: [String] = []
    public var removed: [String] = []
    public var skipped = 0

    public var changed: Bool { !(added.isEmpty && replaced.isEmpty && removed.isEmpty) }
}
