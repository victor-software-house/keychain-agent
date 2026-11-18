import Foundation
import KeyStore

/// What `signd status` shows about syncing, from the token store, the settings and `sync.json`.
public struct SyncStatus: Codable, Sendable {
    public struct Interval: Codable, Sendable {
        public let value: String
        public let seconds: Double
        /// `local`, `note` or `default`.
        public let source: Settings.Source
    }

    public struct Skipped: Codable, Sendable {
        public let item: String
        public let itemID: String
        public let vaultID: String
        public let reason: String
    }

    public let signedIn: Bool
    public let interval: Interval
    public let lastCheck: Date?
    public let lastSuccess: Date?
    public let lastResult: CheckOutcome?
    public let lastMessage: String?
    public let nextAttempt: Date?
    /// The requests to 1Password the last check made, and the items it fetched.
    public let requests: Int
    public let fetched: Int
    public let skipped: [Skipped]
    /// The local settings that are not valid, so signd uses the note's value or the default instead.
    public let ignoredSettings: [Settings.Ignored]

    public init(signedIn: Bool, state: SyncState, settings: Settings = Settings()) {
        let interval = settings.resolve(.interval, fleet: state.fleet)
        self.signedIn = signedIn
        self.interval = Interval(value: interval.value, seconds: interval.seconds, source: interval.source)
        lastCheck = state.lastCheck
        lastSuccess = state.lastSuccess
        lastResult = state.lastResult
        lastMessage = state.lastMessage.map(Selection.clean)
        nextAttempt = signedIn ? state.nextAttempt : nil
        requests = state.requests
        fetched = state.fetched
        ignoredSettings = settings.ignored().map {
            Settings.Ignored(key: $0.key, value: Selection.clean($0.value), reason: $0.reason)
        }
        skipped = state.skipped.filter(\.isReported).map {
            Skipped(item: Selection.clean($0.title), itemID: $0.itemID, vaultID: $0.vaultID, reason: Selection.clean($0.reason))
        }
    }
}
