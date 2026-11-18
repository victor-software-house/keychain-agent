import Foundation

/// How long to wait before the next check, from design decisions 7 and 8.
/// `random` returns a value in [0, 1) and is injected so tests fix the jitter.
public struct SyncSchedule: Sendable {
    public let random: @Sendable () -> Double

    /// How often signd asks again for an iCloud account that is not available.
    public static let accountRecheck: TimeInterval = 60
    /// The longest wait after failures in a row.
    public static let longestBackoff: TimeInterval = 60

    public init(random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.random = random
    }

    /// The wait after a check succeeds: the interval times a random factor from 0.8 to 1.2.
    public func afterSuccess(interval: TimeInterval) -> TimeInterval {
        interval * (0.8 + 0.4 * random())
    }

    /// The wait after `failures` failed checks in a row.
    /// It is the interval doubled for each failure before, up to 60 seconds, times a random factor from 0.5 to 1.
    public func afterFailure(interval: TimeInterval, failures: Int) -> TimeInterval {
        min(Self.longestBackoff, interval * pow(2, Double(max(0, failures - 1)))) * (0.5 + 0.5 * random())
    }

    /// The wait after a throttle.
    /// It is the retry-after time CloudKit returned, and at least the interval.
    /// Without a retry-after time, it is the failure backoff.
    public func afterThrottle(interval: TimeInterval, retryAfter: TimeInterval?, failures: Int) -> TimeInterval {
        guard let retryAfter else { return max(interval, afterFailure(interval: interval, failures: failures)) }
        return max(interval, retryAfter)
    }
}
