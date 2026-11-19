import Foundation
import Sync

/// How a run ended.
public enum BackupOutcome: String, Codable, Sendable, Equatable {
    case ok
    case failed
    /// Another Mac held the lease, so this run wrote nothing.
    case held
    /// No backup token is stored, so the backup is off and nothing ran.
    case off
}

/// What a run did.
public struct BackupResult: Sendable, Equatable {
    public var outcome: BackupOutcome
    /// Why the run did not end well; it contains no secret.
    public var message: String?

    public init(_ outcome: BackupOutcome, _ message: String? = nil) {
        self.outcome = outcome
        self.message = message
    }
}

/// What the agent keeps about the backup, in `backup.json` beside `sync.json`.
/// It contains no secret.
public struct BackupState: Codable, Sendable, Equatable {
    public static let currentFormat = 1

    public var format = Self.currentFormat
    /// The last key change that no run has covered; nil when none is waiting.
    public var lastChange: Date?
    /// When the last run began.
    public var lastRun: Date?
    /// When the last run that ended well began.
    public var lastSuccess: Date?
    public var lastOutcome: BackupOutcome?
    public var lastError: String?

    public init() {}

    /// `~/Library/Application Support/signd/backup.json`.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/signd/backup.json")
    }

    /// The state in `url`, or an empty one when the file is absent, unreadable or of another format.
    public static func load(from url: URL = defaultURL) -> BackupState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(BackupState.self, from: data), state.format == currentFormat else {
            return BackupState()
        }
        return state
    }

    public func save(to url: URL = Self.defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(self), to: url, mode: 0o600)
    }
}

/// The cache of the vault's items, in `backup-cache.json`.
/// It contains no secret.
public enum BackupCache {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/signd/backup-cache.json")
    }

    /// The cache in `url`, or an empty one when the file is absent or unreadable.
    /// An empty cache makes the next run read every tagged item.
    static func load(from url: URL) -> [String: BackupCacheEntry] {
        guard let data = try? Data(contentsOf: url), let cache = try? JSONDecoder().decode([String: BackupCacheEntry].self, from: data) else { return [:] }
        return cache
    }

    /// The default encoder keeps each date exact, which a run compares for equality with the vault's.
    static func save(_ cache: [String: BackupCacheEntry], to url: URL) throws {
        try AtomicFile.write(try JSONEncoder().encode(cache), to: url, mode: 0o600)
    }
}
