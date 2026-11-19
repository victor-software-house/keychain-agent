import Foundation

/// When a run of the updater goes on, by design decision 2.
/// The clock and the random source are injected, so tests fix both.
public struct UpdateSchedule: Sendable {
    /// The longest wait before a due run goes on, so Macs do not check together.
    public static let longestDelay: TimeInterval = 600

    public let now: @Sendable () -> Date
    /// Returns a value in [0, 1).
    public let random: @Sendable () -> Double

    public init(now: @escaping @Sendable () -> Date = { Date() }, random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.now = now
        self.random = random
    }

    /// Whether `interval` has passed since `lastCheck`; a Mac that never checked is due.
    public func isDue(lastCheck: Date?, interval: TimeInterval) -> Bool {
        guard let lastCheck else { return true }
        return now().timeIntervalSince(lastCheck) >= interval
    }

    /// How long a due run waits before it goes on.
    public func delay() -> TimeInterval {
        Self.longestDelay * random()
    }
}
