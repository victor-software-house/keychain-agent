import Foundation
import KeyStore

/// When a backup run is due, by design decision 4.
///
/// A run is due `delay` after the last key change, and at most once per `interval`.
/// With no change pending, it is due once per `daily`.
/// A Mac that never ran is due at once.
/// The caller supplies the dates, so a test needs no clock.
public struct BackupSchedule: Sendable, Equatable {
    public var delay: TimeInterval
    public var interval: TimeInterval
    public var daily: TimeInterval

    public init(delay: TimeInterval = 300, interval: TimeInterval = 3600, daily: TimeInterval = 86400) {
        self.delay = delay
        self.interval = interval
        self.daily = daily
    }

    /// The three durations of the `backup-delay`, `backup-interval` and `backup-daily-interval` settings.
    public init(settings: Settings) {
        self.init(
            delay: settings.resolve(.backupDelay).seconds, interval: settings.resolve(.backupInterval).seconds,
            daily: settings.resolve(.backupDailyInterval).seconds
        )
    }

    /// When the next run is due.
    /// `lastChange` is the last key change that no run has covered, and `lastRun` is when the last run began.
    public func due(lastChange: Date?, lastRun: Date?) -> Date {
        if let lastChange {
            let slot = lastRun.map { $0.addingTimeInterval(interval) } ?? .distantPast
            return max(lastChange.addingTimeInterval(delay), slot)
        }
        return lastRun.map { $0.addingTimeInterval(daily) } ?? .distantPast
    }

    /// How long to wait from `now` for the next run, never negative.
    public func wait(lastChange: Date?, lastRun: Date?, now: Date) -> TimeInterval {
        max(0, due(lastChange: lastChange, lastRun: lastRun).timeIntervalSince(now))
    }
}
