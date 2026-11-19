import Foundation
import os

private let log = Logger(subsystem: "com.victor-software-house.signd", category: "backup")

/// Starts a backup run on the schedule, and records how each ended.
///
/// The agent starts it beside the sync service.
/// A run takes no part in a key change or an SSH request: it runs in a task of its own, off this actor.
public actor BackupService {
    public struct Dependencies: Sendable {
        /// One run; `BackupRun.perform`.
        public var run: @Sendable () async -> BackupResult
        /// The schedule from the settings, read each time so a changed setting applies at the next wait.
        public var schedule: @Sendable () -> BackupSchedule
        public var now: @Sendable () -> Date
        public var sleep: @Sendable (_ seconds: TimeInterval) async throws -> Void
        public var stateURL: URL

        public init(
            run: @escaping @Sendable () async -> BackupResult, schedule: @escaping @Sendable () -> BackupSchedule,
            now: @escaping @Sendable () -> Date = { Date() },
            sleep: @escaping @Sendable (_ seconds: TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0), tolerance: .seconds(1)) },
            stateURL: URL = BackupState.defaultURL
        ) {
            self.run = run
            self.schedule = schedule
            self.now = now
            self.sleep = sleep
            self.stateURL = stateURL
        }
    }

    private let dependencies: Dependencies
    private var state = BackupState()
    private var isStarted = false
    private var isRunning = false
    private var timer: Task<Void, Never>?

    public init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Reads the state and waits for the next run.
    public func start() {
        state = BackupState.load(from: dependencies.stateURL)
        isStarted = true
        arm()
    }

    /// The state as it stands, for `signd status`.
    public func snapshot() -> BackupState { state }

    /// Shared keys changed: the next run is due after the delay.
    public func keysDidChange() {
        guard isStarted else { return }
        state.lastChange = dependencies.now()
        persist()
        // A run in progress arms the timer again when it ends.
        if !isRunning { arm() }
    }

    /// A setting changed.
    /// The wait is computed again from the new schedule, and no key change is recorded.
    public func scheduleDidChange() {
        guard isStarted else { return }
        // A run in progress arms the timer again when it ends.
        if !isRunning { arm() }
    }

    /// Waits until the next slot, or `seconds` when the caller names it.
    private func arm(waiting seconds: TimeInterval? = nil) {
        timer?.cancel()
        let wait = seconds ?? dependencies.schedule().timeUntilNextRun(lastChange: state.lastChange, lastRun: state.lastRun, now: dependencies.now())
        let sleep = dependencies.sleep
        timer = Task {
            do {
                try await sleep(wait)
            } catch {
                return
            }
            await self.fire()
        }
    }

    /// Runs the backup now, and waits for the next slot.
    /// A failed run keeps its key change waiting, so the next slot is one interval after it began, and no run follows it at once.
    func fire() async {
        guard !Task.isCancelled, !isRunning else { return }
        // The timer that called this keeps running through the run; a key change during it must not cancel it.
        timer = nil
        isRunning = true
        let began = dependencies.now()
        let covered = state.lastChange
        state.lastChange = nil
        let result = await dependencies.run()
        isRunning = false
        switch result.outcome {
        case .off:
            // No token is stored and nothing ran. Ask again after an interval.
            state.lastChange = state.lastChange ?? covered
            arm(waiting: dependencies.schedule().minimumInterval)
            return
        case .ok:
            state.lastSuccess = began
            state.lastError = nil
        case .failed, .held:
            state.lastChange = state.lastChange ?? covered ?? began
            state.lastError = result.message
        }
        state.lastRun = began
        state.lastOutcome = result.outcome
        persist()
        arm()
    }

    private func persist() {
        do {
            try state.save(to: dependencies.stateURL)
        } catch {
            log.error("cannot write the backup state: \(String(describing: error), privacy: .public)")
        }
    }
}
