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

/// Counts token changes, so a check that started under an old token can tell, as it never holds the actor between its steps.
final class Epoch: Sendable {
    private let storage = Mutex(0)

    var value: Int { storage.withLock { $0 } }

    func bump() { storage.withLock { $0 += 1 } }
}

/// What `signd logout` did in the agent.
public struct LogoutResult: Codable, Sendable, Equatable {
    public var ok: Bool
    public var removed: Int

    public init(ok: Bool, removed: Int) {
        self.ok = ok
        self.removed = removed
    }
}

/// Checks 1Password on a schedule and keeps the stored keys in step with it.
///
/// Nothing a client request does awaits this actor: `noteRequest` only reads and sets a small gate, and starts any check on its own task.
public actor SyncService {
    public struct Dependencies: Sendable {
        public var token: @Sendable () throws(StoreError) -> String?
        public var deleteToken: @Sendable () throws(StoreError) -> Void
        public var makeSource: SourceFactory
        public var store: any KeyStore
        public var wrap: KeyWrapper
        public var hostName: @Sendable () -> String
        /// The running signd's version.
        public var version: String
        /// The interval in seconds, from the settings and the note's values.
        public var interval: @Sendable (_ fleet: [String: String]) -> TimeInterval
        public var now: @Sendable () -> Date
        public var sleep: @Sendable (_ seconds: TimeInterval) async throws -> Void
        public var schedule: SyncSchedule
        public var stateURL: URL
        /// Called after a check or a logout changed keys, so the agent reads them.
        public var changed: @Sendable () async -> Void

        public init(
            token: @escaping @Sendable () throws(StoreError) -> String?, deleteToken: @escaping @Sendable () throws(StoreError) -> Void,
            makeSource: @escaping SourceFactory, store: any KeyStore, wrap: @escaping KeyWrapper,
            hostName: @escaping @Sendable () -> String = { Selection.localHostName() }, version: String,
            interval: @escaping @Sendable (_ fleet: [String: String]) -> TimeInterval,
            now: @escaping @Sendable () -> Date = { Date() },
            sleep: @escaping @Sendable (_ seconds: TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0), tolerance: .seconds(1)) },
            schedule: SyncSchedule = SyncSchedule(), stateURL: URL = SyncState.defaultURL,
            changed: @escaping @Sendable () async -> Void
        ) {
            self.token = token
            self.deleteToken = deleteToken
            self.makeSource = makeSource
            self.store = store
            self.wrap = wrap
            self.hostName = hostName
            self.version = version
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

    private enum Ended {
        case done(SyncState)
        case failed(CheckOutcome, String)
        case stale
    }

    /// `signd sync` within this long of the last check gets that check's result, so a loop of calls cannot use up the rate limit.
    private static let syncWindow: TimeInterval = 60

    public nonisolated let fleet: FleetSettings
    private nonisolated let gate = Mutex(Gate())
    private nonisolated let epoch = Epoch()
    private let dependencies: Dependencies
    private var state = SyncState()
    private var token: String?
    private var source: (any OnePasswordSource)?
    private var clientTask: Task<Result<any OnePasswordSource, OnePasswordError>, Never>?
    private var checkTask: Task<CheckSummary, Never>?
    private var timer: Task<Void, Never>?
    private var lastSummary: (summary: CheckSummary, at: Date)?

    public init(_ dependencies: Dependencies, fleet: FleetSettings = FleetSettings()) {
        self.dependencies = dependencies
        self.fleet = fleet
    }

    /// Reads the state and the token, opens the client in the background when a token is stored, and schedules the first check.
    public func start() {
        configure(force: true)
    }

    /// Reads the token again, as after a key command; a token that has not changed keeps the schedule.
    public func reconfigure() {
        configure(force: false)
    }

    /// Starts again from an empty state and the stored token, as after `signd login`, even when the token is the same one,
    /// so that a token the last login found refused gets a new try. The state file goes after the epoch moves,
    /// so a check that started under the old token cannot write it again.
    public func login() {
        epoch.bump()
        SyncState.remove(at: dependencies.stateURL)
        state = SyncState()
        configure(force: true)
    }

    /// Signs out: clears the token, drops the check in flight, and deletes the synced keys and the state.
    /// The check in flight cannot write after this returns, because it asks before each write whether its token is still current.
    public func logout() async -> LogoutResult {
        epoch.bump()
        timer?.cancel()
        timer = nil
        checkTask?.cancel()
        checkTask = nil
        clientTask?.cancel()
        clientTask = nil
        source = nil
        token = nil
        lastSummary = nil
        var result = LogoutResult(ok: true, removed: 0)
        do {
            try dependencies.deleteToken()
        } catch {
            log.error("cannot delete the token: \(error.description, privacy: .public)")
            result.ok = false
        }
        SyncState.remove(at: dependencies.stateURL)
        state = SyncState()
        fleet.set([:])
        do {
            for key in try dependencies.store.list() where key.isSynced {
                try dependencies.store.delete(name: key.name)
                result.removed += 1
            }
        } catch {
            log.error("cannot delete the synced keys: \(error.description, privacy: .public)")
            result.ok = false
        }
        gate.withLock { $0.tokenUnreadable = false }
        publish()
        await dependencies.changed()
        return result
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

    /// What `signd sync` asks for: a check now, unless one ended less than a minute ago, and then that one's result.
    public func syncRequested() async -> CheckSummary {
        if checkTask == nil, let last = lastSummary, dependencies.now().timeIntervalSince(last.at) < Self.syncWindow {
            return last.summary
        }
        return await performCheck()
    }

    // MARK: Configuration

    private func configure(force: Bool) {
        let current: String?
        do throws(StoreError) {
            current = try dependencies.token()
            gate.withLock { $0.tokenUnreadable = false }
        } catch {
            log.error("cannot read the token: \(error.description, privacy: .public)")
            gate.withLock { $0.tokenUnreadable = true }
            return
        }
        if !force && current == token { return }
        epoch.bump()
        token = current
        timer?.cancel()
        timer = nil
        checkTask?.cancel()
        checkTask = nil
        clientTask?.cancel()
        clientTask = nil
        source = nil
        lastSummary = nil
        state = SyncState.load(from: dependencies.stateURL)
        fleet.set(state.fleet)
        guard let current else {
            publish()
            return
        }
        _ = startClient(current)
        Task { await self.warm() }
        if state.lastResult != .tokenRefused {
            let now = dependencies.now()
            let interval = dependencies.interval(state.fleet)
            var delay = dependencies.schedule.phase(interval: interval)
            // A restart does not cut a backoff or a rate-limit wait short.
            if let next = state.nextAttempt, state.lastResult == .rateLimited || state.lastResult == .failed, next > now {
                delay = max(delay, next.timeIntervalSince(now))
            }
            state.nextAttempt = now.addingTimeInterval(delay)
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

    /// Opens the client in the background, so the first check finds it ready. A failure is only logged: each check opens it again.
    private func warm() async {
        do throws(OnePasswordError) {
            _ = try await ensureSource()
        } catch {
            log.error("cannot open the 1Password client: \(error.message, privacy: .public)")
        }
    }

    private func ensureSource() async throws(OnePasswordError) -> any OnePasswordSource {
        if let source { return source }
        guard let token else { throw OnePasswordError(kind: .other, message: "no token is stored") }
        let opened = epoch.value
        let task = clientTask ?? startClient(token)
        let result = await task.value
        guard opened == epoch.value else { throw OnePasswordError(kind: .other, message: "the token changed") }
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
        if checkTask == task { checkTask = nil }
        return summary
    }

    private func runCheck() async -> CheckSummary {
        defer { gate.withLock { $0.running = false } }
        guard token != nil else {
            return CheckSummary(outcome: .notSignedIn, message: "no token is stored; run signd login")
        }
        gate.withLock { $0.running = true }
        let started = epoch.value
        let epoch = epoch
        var counters = Counters()
        var changes = Changes()
        var ended: Ended

        var opening: OnePasswordError?
        var client: (any OnePasswordSource)?
        do throws(OnePasswordError) {
            client = try await ensureSource()
        } catch {
            opening = error
        }
        if let client {
            let check = SyncCheck(
                source: client, store: dependencies.store, wrap: dependencies.wrap, hostName: dependencies.hostName(),
                isCurrent: { epoch.value == started }, version: dependencies.version
            )
            do {
                ended = .done(try await check.run(from: state, counters: &counters, changes: &changes, isolation: self))
            } catch is Stale {
                ended = .stale
            } catch let error as OnePasswordError {
                // Only a call that 1Password answers can show that it refuses the token.
                switch error.kind {
                case .authentication: ended = .failed(.tokenRefused, "1Password refused the token: \(error.message)")
                case .rateLimited: ended = .failed(.rateLimited, "1Password rate limited the check")
                case .decoding, .other: ended = .failed(.failed, error.message)
                }
            } catch let error as StoreError {
                ended = .failed(.failed, error.description)
            } catch {
                ended = .failed(.failed, String(describing: error))
            }
        } else {
            let reason = opening?.message ?? "the client did not open"
            switch opening?.kind {
            case .authentication?: ended = .failed(.tokenRefused, "1Password refused the token: \(reason)")
            case .rateLimited?: ended = .failed(.rateLimited, "cannot open the 1Password client: \(reason)")
            case .decoding?, .other?, nil: ended = .failed(.failed, "cannot open the 1Password client: \(reason)")
            }
        }
        if epoch.value != started { ended = .stale }

        if case .stale = ended {
            if !changes.isEmpty { await dependencies.changed() }
            return CheckSummary(
                outcome: .failed, message: "the token changed during the check", requests: counters.requests, fetched: counters.fetched,
                added: changes.added, replaced: changes.replaced, removed: changes.removed
            )
        }

        let now = dependencies.now()
        let schedule = dependencies.schedule
        var outcome = CheckOutcome.ok
        var message: String?
        var updated = state
        switch ended {
        case let .done(next): updated = next
        case let .failed(kind, reason):
            outcome = kind
            message = Selection.clean(reason)
        case .stale: break
        }
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
        let summary = CheckSummary(
            outcome: outcome, message: message, requests: counters.requests, fetched: counters.fetched,
            added: changes.added, replaced: changes.replaced, removed: changes.removed, skipped: updated.skipped.filter(\.isReported).count
        )
        // A logout or a login during `changed` already started over, so this check's result and schedule are no longer the service's.
        if epoch.value == started {
            scheduleNext()
            lastSummary = (summary, now)
        }
        return summary
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
