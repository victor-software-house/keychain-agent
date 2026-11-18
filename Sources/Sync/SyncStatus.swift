import Foundation
import KeyStore

/// What `signd status` shows about syncing, from the settings and the sync state.
public struct SyncStatus: Codable, Sendable {
    public struct Interval: Codable, Sendable {
        public let value: String
        public let seconds: Double
        /// `local` or `default`.
        public let source: Settings.Source
    }

    public struct Key: Codable, Sendable {
        public let name: String
        public let record: String
        public let kind: SkipKind
        public let reason: String
    }

    /// `on`, `off in this build`, `no account`, `stopped`, `backing off` or `not checked yet`.
    public let state: String
    public let interval: Interval
    public let lastCheck: Date?
    public let lastSuccess: Date?
    public let lastResult: CheckOutcome?
    public let lastMessage: String?
    public let nextAttempt: Date?
    public let lastPush: Date?
    /// The requests the last check made.
    public let requests: Int
    /// The devices on the account, this one included.
    public let devices: Int
    /// Shared keys this device waits for or skips.
    public let skipped: [Key]
    /// The local settings that are not valid, so signd uses the default instead.
    public let ignoredSettings: [Settings.Ignored]

    public init(state sync: SyncState, settings: Settings = Settings()) {
        let interval = settings.resolve(.interval)
        state = switch sync.lastResult {
        case .ok?: "on"
        case .off?: "off in this build"
        case .accountUnavailable?: "no account"
        case .stopped?: "stopped"
        case .failed?, .throttled?: "backing off"
        case nil: "not checked yet"
        }
        self.interval = Interval(value: interval.value, seconds: interval.seconds, source: interval.source)
        lastCheck = sync.lastCheck
        lastSuccess = sync.lastSuccess
        lastResult = sync.lastResult
        lastMessage = sync.lastMessage.map(Display.clean)
        nextAttempt = sync.nextAttempt
        lastPush = sync.lastPush
        requests = sync.requests
        devices = sync.devices.count
        skipped = sync.skipped.map { Key(name: Display.clean($0.name), record: $0.record, kind: $0.kind, reason: Display.clean($0.reason)) }
        ignoredSettings = settings.ignored().map {
            Settings.Ignored(key: $0.key, value: Display.clean($0.value), reason: $0.reason)
        }
    }
}
