import Foundation
import KeyStore

/// When a backup run is due, by design decision 4.
///
/// A run is due `delay` after the last key change, and at most once per `minimumInterval`.
/// With no change pending, it is due once per `maximumInterval`.
/// A Mac that never ran is due at once.
/// The caller supplies the dates, so a test needs no clock.
public struct BackupSchedule: Sendable, Equatable {
    public var delay: TimeInterval
    public var minimumInterval: TimeInterval
    public var maximumInterval: TimeInterval

    public init(delay: TimeInterval = 300, minimumInterval: TimeInterval = 3600, maximumInterval: TimeInterval = 86400) {
        self.delay = delay
        self.minimumInterval = minimumInterval
        self.maximumInterval = maximumInterval
    }

    /// The three durations of the `backup-delay`, `backup-min-interval` and `backup-max-interval` settings.
    public init(settings: Settings) {
        self.init(
            delay: settings.resolve(.backupDelay).seconds, minimumInterval: settings.resolve(.backupMinInterval).seconds,
            maximumInterval: settings.resolve(.backupMaxInterval).seconds
        )
    }

    /// When the next run is due.
    /// `lastChange` is the last key change that no run has covered, and `lastRun` is when the last run began.
    public func nextRun(lastChange: Date?, lastRun: Date?) -> Date {
        if let lastChange {
            let slot = lastRun.map { $0.addingTimeInterval(minimumInterval) } ?? .distantPast
            return max(lastChange.addingTimeInterval(delay), slot)
        }
        return lastRun.map { $0.addingTimeInterval(maximumInterval) } ?? .distantPast
    }

    /// How long to wait from `now` for the next run, never negative.
    public func timeUntilNextRun(lastChange: Date?, lastRun: Date?, now: Date) -> TimeInterval {
        max(0, nextRun(lastChange: lastChange, lastRun: lastRun).timeIntervalSince(now))
    }
}
