import Foundation
import os

private let log = Logger(subsystem: "com.victor-software-house.signd", category: "updater")

/// Runs the checks one at a time and records how each ended, in `update.json`.
///
/// Each request during a check gets that check's result.
/// Each request within 5 minutes of the last recorded check gets the recorded result, with no new request to GitHub.
///
/// A check that made no request, because updates are off, is never reused: the setting may have changed.
/// The actor does none of the work of a check: `run` does it on the global executor.
public actor Updater {
    /// How long a recorded check answers later requests.
    static let recheckWindow: TimeInterval = 300

    private let run: @Sendable () async -> UpdateState
    private let now: @Sendable () -> Date
    private let stateURL: URL
    private var state: UpdateState
    private var running: Task<UpdateState, Never>?
    private var lastActivity: Date
    private var isStopping = false

    /// `run` performs one check; `UpdateRun.perform`.
    public init(run: @escaping @Sendable () async -> UpdateState, now: @escaping @Sendable () -> Date = { Date() }, stateURL: URL = UpdateState.defaultURL) {
        self.run = run
        self.now = now
        self.stateURL = stateURL
        state = UpdateState.load(from: stateURL)
        lastActivity = now()
    }

    /// Checks now, or answers with the check that is running or was recorded in the last 5 minutes.
    /// After `shutdown` it refuses, with a failed result that asks for a new request, since the process is about to exit.
    public func check() async -> UpdateState {
        if isStopping {
            var refused = state
            refused.outcome = .failed
            refused.error = "the updater is shutting down; run the request again"
            return refused
        }
        lastActivity = now()
        if let running { return await running.value }
        if let outcome = state.outcome, outcome != .off, let last = state.lastCheck, now().timeIntervalSince(last) < Self.recheckWindow { return state }
        let task = Task { await self.perform() }
        running = task
        let result = await task.value
        running = nil
        lastActivity = now()
        return result
    }

    /// Whether no check is running and none began or ended in the last `seconds`.
    public func isIdle(for seconds: TimeInterval) -> Bool {
        running == nil && now().timeIntervalSince(lastActivity) >= seconds
    }

    /// Marks the updater as stopping, unless a check runs or began or ended in the last `seconds`.
    /// It returns whether it did: the caller exits the process only then, and later `check` calls refuse.
    public func shutdown(idleFor seconds: TimeInterval) -> Bool {
        guard isIdle(for: seconds) else { return false }
        isStopping = true
        return true
    }

    private func perform() async -> UpdateState {
        let result = await run()
        state = result
        do {
            try result.save(to: stateURL)
        } catch {
            log.error("cannot write the update state: \(String(describing: error), privacy: .public)")
        }
        return result
    }
}
