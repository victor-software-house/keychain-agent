import Foundation
import KeyStore
import OnePassword
import os
import Synchronization

private let log = Logger(subsystem: "com.victor-software-house.signd", category: "sync")

/// The `signd` note's settings, which the agent reads without waiting for a check.
public final class FleetSettings: Sendable {
    private let storage = Mutex<[String: String]>([:])

    public init() {}

    public var values: [String: String] { storage.withLock { $0 } }

    func set(_ values: [String: String]) { storage.withLock { $0 = values } }
}

/// Checks 1Password on a schedule and keeps the stored keys in step with it.
///
/// Nothing a client request does awaits this actor: `noteRequest` only reads and sets a small gate, and starts any check on its own task.
public actor SyncService {
    public struct Dependencies: Sendable {
        public var token: @Sendable () throws(StoreError) -> String?
        public var makeSource: SourceFactory
        public var store: any KeyStore
        public var wrap: KeyWrapper
        public var hostName: @Sendable () -> String
        /// The interval in seconds, from the settings and the note's values.
        public var interval: @Sendable (_ fleet: [String: String]) -> TimeInterval
        public var now: @Sendable () -> Date
        public var sleep: @Sendable (_ seconds: TimeInterval) async throws -> Void
        public var schedule: SyncSchedule
        public var stateURL: URL
        /// Called after a check changed keys, so the agent reads them.
        public var changed: @Sendable () async -> Void

        public init(
            token: @escaping @Sendable () throws(StoreError) -> String?, makeSource: @escaping SourceFactory, store: any KeyStore,
            wrap: @escaping KeyWrapper, hostName: @escaping @Sendable () -> String = { Selection.localHostName() },
            interval: @escaping @Sendable (_ fleet: [String: String]) -> TimeInterval,
            now: @escaping @Sendable () -> Date = { Date() },
            sleep: @escaping @Sendable (_ seconds: TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0), tolerance: .seconds(1)) },
            schedule: SyncSchedule = SyncSchedule(), stateURL: URL = SyncState.defaultURL,
            changed: @escaping @Sendable () async -> Void
        ) {
            self.token = token
            self.makeSource = makeSource
            self.store = store
            self.wrap = wrap
            self.hostName = hostName
            self.interval = interval
            self.now = now
            self.sleep = sleep
            self.schedule = schedule
            self.stateURL = stateURL
            self.changed = changed
        }
    }

    private struct Gate {
        var enabled = false
        var tokenUnreadable = false
        var running = false
        var lastSuccess: Date?
        var lastOutcome: CheckOutcome?
        var nextAttempt: Date?
        var interval: TimeInterval = 300
    }

    private enum Action {
        case none, check, readToken
    }

    public nonisolated let fleet: FleetSettings
    private nonisolated let gate = Mutex(Gate())
    private let dependencies: Dependencies
    private var state = SyncState()
    private var token: String?
    private var source: (any OnePasswordSource)?
    private var clientTask: Task<Result<any OnePasswordSource, OnePasswordError>, Never>?
    private var startupError: OnePasswordError?
    private var checkTask: Task<CheckSummary, Never>?
    private var timer: Task<Void, Never>?
    /// Counts token changes, so a client opened for an old token is dropped.
    private var generation = 0

    public init(_ dependencies: Dependencies, fleet: FleetSettings = FleetSettings()) {
        self.dependencies = dependencies
        self.fleet = fleet
    }

    /// Reads the state and the token, opens the client in the background when a token is stored, and schedules the first check.
    public func start() {
        configure(initial: true)
    }

    /// Reads the token again, as after `signd login` or `signd logout`.
    public func reconfigure() {
        configure(initial: false)
    }

    /// A list or sign request happened: when the last success is older than the interval, starts a check in the background and returns at once.
    public nonisolated func noteRequest() {
        let now = dependencies.now()
        let action = gate.withLock { gate -> Action in
            guard !gate.running else { return .none }
            if gate.tokenUnreadable {
                gate.running = true
                return .readToken
            }
            guard gate.enabled else { return .none }
            let stale = gate.lastSuccess.map { now.timeIntervalSince($0) > gate.interval } ?? true
            let allowed = gate.lastOutcome == nil || gate.lastOutcome == .ok || (gate.nextAttempt.map { now >= $0 } ?? false)
            guard stale && allowed else { return .none }
            gate.running = true
            return .check
        }
        switch action {
        case .none:
            break
        case .check:
            Task { _ = await self.performCheck() }
        case .readToken:
            Task {
                await self.reconfigure()
                self.gate.withLock { $0.running = false }
            }
        }
    }

    /// Runs a check now, or joins the one running, and returns its result.
    public func checkNow() async -> CheckSummary {
        await performCheck()
    }

    // MARK: Configuration

    private func configure(initial: Bool) {
        let current: String?
        do throws(StoreError) {
            current = try dependencies.token()
            gate.withLock { $0.tokenUnreadable = false }
        } catch {
            log.error("cannot read the token: \(error.description, privacy: .public)")
            gate.withLock { $0.tokenUnreadable = true }
            return
        }
        if !initial && current == token { return }
        generation += 1
        token = current
        timer?.cancel()
        timer = nil
        checkTask?.cancel()
        clientTask?.cancel()
        clientTask = nil
        source = nil
        startupError = nil
        state = SyncState.load(from: dependencies.stateURL)
        fleet.set(state.fleet)
        guard let current else {
            publish()
            return
        }
        _ = startClient(current)
        Task { await self.warm() }
        if state.lastResult != .tokenRefused {
            let interval = dependencies.interval(state.fleet)
            let delay = dependencies.schedule.phase(interval: interval)
            state.nextAttempt = dependencies.now().addingTimeInterval(delay)
            persist()
            startTimer(delay)
        }
        publish()
    }

    private func publish() {
        let interval = dependencies.interval(state.fleet)
        gate.withLock { gate in
            gate.enabled = token != nil
            gate.lastSuccess = state.lastSuccess
            gate.lastOutcome = state.lastResult
            gate.nextAttempt = state.nextAttempt
            gate.interval = interval
        }
    }

    private func persist() {
        do {
            try state.save(to: dependencies.stateURL)
        } catch {
            log.error("cannot write the sync state: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: The client

    private func startClient(_ token: String) -> Task<Result<any OnePasswordSource, OnePasswordError>, Never> {
        let make = dependencies.makeSource
        let task = Task { () -> Result<any OnePasswordSource, OnePasswordError> in
            do throws(OnePasswordError) {
                return .success(try await make(token))
            } catch {
                return .failure(error)
            }
        }
        clientTask = task
        return task
    }

    /// Opens the client in the background, so the first check finds it ready.
    private func warm() async {
        do throws(OnePasswordError) {
            _ = try await ensureSource()
        } catch {
            startupError = error
        }
    }

    private func ensureSource() async throws(OnePasswordError) -> any OnePasswordSource {
        if let source { return source }
        guard let token else { throw OnePasswordError(kind: .authentication, message: "no token is stored") }
        let opened = generation
        let task = clientTask ?? startClient(token)
        let result = await task.value
        guard opened == generation else { throw OnePasswordError(kind: .other, message: "the token changed") }
        if clientTask == task { clientTask = nil }
        switch result {
        case let .success(client):
            source = client
            return client
        case let .failure(error):
            throw error
        }
    }

    // MARK: Checks

    private func performCheck() async -> CheckSummary {
        if let running = checkTask { return await running.value }
        let task = Task { await self.runCheck() }
        checkTask = task
        let summary = await task.value
        checkTask = nil
        return summary
    }

    private func runCheck() async -> CheckSummary {
        defer { gate.withLock { $0.running = false } }
        guard token != nil else {
            return CheckSummary(outcome: .notSignedIn, message: "no token is stored; run signd login")
        }
        gate.withLock { $0.running = true }
        var counters = Counters()
        var changes = Changes()
        var outcome = CheckOutcome.ok
        var message: String?
        var next = state
        do {
            if let error = startupError {
                startupError = nil
                throw error
            }
            let client = try await ensureSource()
            let check = SyncCheck(source: client, store: dependencies.store, wrap: dependencies.wrap, hostName: dependencies.hostName())
            next = try await check.run(from: state, counters: &counters, changes: &changes)
        } catch let error as OnePasswordError {
            switch error.kind {
            case .authentication:
                outcome = .tokenRefused
                message = "1Password refused the token: \(error.message)"
            case .rateLimited:
                outcome = .rateLimited
                message = "1Password rate limited the check"
            case .other:
                outcome = .failed
                message = error.message
            }
        } catch let error as StoreError {
            outcome = .failed
            message = error.description
        } catch {
            outcome = .failed
            message = String(describing: error)
        }

        let now = dependencies.now()
        let schedule = dependencies.schedule
        var updated = outcome == .ok ? next : state
        let interval = dependencies.interval(updated.fleet)
        updated.lastCheck = now
        updated.lastResult = outcome
        updated.lastMessage = message
        updated.requests = counters.requests
        updated.fetched = counters.fetched
        switch outcome {
        case .ok:
            updated.lastSuccess = now
            updated.failures = 0
            updated.rateLimits = 0
            updated.nextAttempt = now.addingTimeInterval(schedule.afterSuccess(interval: interval))
        case .failed:
            updated.failures += 1
            updated.rateLimits = 0
            updated.nextAttempt = now.addingTimeInterval(schedule.afterFailure(interval: interval, failures: updated.failures))
        case .rateLimited:
            updated.rateLimits += 1
            updated.failures = 0
            updated.nextAttempt = now.addingTimeInterval(schedule.afterRateLimit(repeats: updated.rateLimits))
        case .tokenRefused, .notSignedIn:
            updated.nextAttempt = nil
        }
        state = updated
        persist()
        fleet.set(updated.fleet)
        publish()
        if !changes.isEmpty { await dependencies.changed() }
        scheduleNext()
        return CheckSummary(
            outcome: outcome, message: message, requests: counters.requests, fetched: counters.fetched,
            added: changes.added, replaced: changes.replaced, removed: changes.removed, skipped: updated.skipped.filter(\.isReported).count
        )
    }

    // MARK: The timer

    private func scheduleNext() {
        timer?.cancel()
        timer = nil
        guard token != nil, let next = state.nextAttempt else { return }
        startTimer(max(0, next.timeIntervalSince(dependencies.now())))
    }

    private func startTimer(_ delay: TimeInterval) {
        timer?.cancel()
        let sleep = dependencies.sleep
        timer = Task {
            do {
                try await sleep(delay)
            } catch {
                return
            }
            await self.timerFired()
        }
    }

    private func timerFired() async {
        guard !Task.isCancelled else { return }
        _ = await performCheck()
    }
}
