import Foundation

/// How long to wait before the next check, from design decisions 6 and 7.
/// `random` returns a value in [0, 1) and is injected so tests fix the jitter.
public struct SyncSchedule: Sendable {
    public let random: @Sendable () -> Double

    public init(random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.random = random
    }

    /// The wait before the first check of a run: a random point within the interval.
    public func phase(interval: TimeInterval) -> TimeInterval {
        random() * interval
    }

    /// The wait after a check succeeds: the interval times a random factor from 0.8 to 1.2.
    public func afterSuccess(interval: TimeInterval) -> TimeInterval {
        interval * (0.8 + 0.4 * random())
    }

    /// The wait after `failures` network or server errors in a row: full jitter up to min(interval, 60 s × 2^(failures − 1)).
    public func afterFailure(interval: TimeInterval, failures: Int) -> TimeInterval {
        random() * min(interval, 60 * pow(2, Double(max(0, failures - 1))))
    }

    /// The wait after `repeats` rate-limit answers in a row: 60 minutes doubling on each repeat, plus up to 10 minutes of jitter, up to 24 hours.
    public func afterRateLimit(repeats: Int) -> TimeInterval {
        min(24 * 3600, 3600 * pow(2, Double(max(0, repeats - 1))) + random() * 600)
    }
}
