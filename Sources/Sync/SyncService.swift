import Foundation
import KeyStore
import os

private let log = Logger(subsystem: "com.victor-software-house.signd", category: "sync")

/// Checks iCloud on a schedule and on each push, and keeps the shared keys in step with it.
///
/// Nothing a list or sign request does awaits this actor. Checks and the commands that change shared keys run one at a time.
public actor SyncService {
    public struct Dependencies: Sendable {
        /// The iCloud database.
        /// It is nil in a build without signd's iCloud entitlement, and that build keeps every key local.
        public var cloud: (any CloudStore)?
        public var store: any KeyStorage
        public var device: @Sendable () throws(StoreError) -> DeviceKey
        public var open: KeyOpener
        /// Where this Mac keeps the backup token.
        public var tokens: any TokenStore
        /// Opens this Mac's sealed copy of the backup token.
        public var openSecret: SecretOpener
        public var deviceName: @Sendable () -> String
        /// The running signd's version.
        public var version: String
        /// The interval in seconds, from the settings.
        public var interval: @Sendable () -> TimeInterval
        public var now: @Sendable () -> Date
        public var sleep: @Sendable (_ seconds: TimeInterval) async throws -> Void
        public var schedule: SyncSchedule
        public var stateURL: URL
        /// Called after shared keys changed, so the agent reads them.
        public var onSharedKeysChanged: @Sendable () async -> Void

        public init(
            cloud: (any CloudStore)?, store: any KeyStorage, device: @escaping @Sendable () throws(StoreError) -> DeviceKey, open: @escaping KeyOpener,
            tokens: any TokenStore, openSecret: @escaping SecretOpener,
            deviceName: @escaping @Sendable () -> String = { ThisDevice.name() }, version: String,
            interval: @escaping @Sendable () -> TimeInterval,
            now: @escaping @Sendable () -> Date = { Date() },
            sleep: @escaping @Sendable (_ seconds: TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0), tolerance: .milliseconds(250)) },
            schedule: SyncSchedule = SyncSchedule(), stateURL: URL = SyncState.defaultURL,
            onSharedKeysChanged: @escaping @Sendable () async -> Void
        ) {
            self.cloud = cloud
            self.store = store
            self.device = device
            self.open = open
            self.tokens = tokens
            self.openSecret = openSecret
            self.deviceName = deviceName
            self.version = version
            self.interval = interval
            self.now = now
            self.sleep = sleep
            self.schedule = schedule
            self.stateURL = stateURL
            self.onSharedKeysChanged = onSharedKeysChanged
        }
    }

    static let offMessage = "this build has no iCloud entitlement, so keys stay on this Mac"
    static let stoppedMessage = "signd's data was deleted in iCloud settings; run signd sync to start again"

    private let dependencies: Dependencies
    private var state = SyncState()
    /// The account the last call found; nil until asked, and after macOS reports a change.
    private var account: CloudAccount?
    private var lastPush: Date?
    /// The state as last written, without the fields that change at every check.
    private var written: SyncState?
    private var writtenAt: Date?
    private var timer: Task<Void, Never>?
    private var current: Task<CheckSummary, Never>?
    /// The last queued check or command, which the next one waits for.
    private var tail: Task<Void, Never>?

    public init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Reads the state and checks at once, or records that sync is off in this build.
    public func start() {
        state = SyncState.load(from: dependencies.stateURL)
        guard dependencies.cloud != nil else {
            state.lastResult = .off
            state.lastMessage = Self.offMessage
            state.nextAttempt = nil
            persist(force: true)
            return
        }
        guard !state.isStopped else { return }
        startTimer(0)
    }

    /// The sync state as it stands, for `signd status`.
    public func snapshot() -> SyncState {
        var snapshot = state
        snapshot.lastPush = lastPush ?? state.lastPush
        return snapshot
    }

    /// A CloudKit push arrived: checks now, unless a check runs, signd is backing off, or checks are stopped.
    public nonisolated func pushArrived() {
        Task { await self.pushed() }
    }

    private func pushed() {
        lastPush = dependencies.now()
        guard dependencies.cloud != nil, current == nil, state.failures == 0, !state.isStopped else { return }
        startTimer(0)
    }

    /// macOS reported another iCloud account, or none: asks again at the next check, which starts now.
    public nonisolated func accountChanged() {
        Task { await self.forgetAccount() }
    }

    private func forgetAccount() {
        account = nil
        guard dependencies.cloud != nil, current == nil, !state.isStopped else { return }
        startTimer(0)
    }

    /// Called when a command changed the store.
    /// It starts a check soon, so a name that a deleted local key freed is taken.
    public func keysDidChange() {
        guard dependencies.cloud != nil, current == nil, state.failures == 0, !state.isStopped else { return }
        startTimer(0)
    }

    /// What `signd sync` requests: a check now.
    /// It also starts again after the zone was deleted in iCloud settings.
    public func syncNow() async -> CheckSummary {
        await check(forced: true)
    }

    /// A check as the timer runs it; for tests.
    /// It joins one in flight.
    func checkNow() async -> CheckSummary {
        await check(forced: false)
    }

    // MARK: Commands

    public func share(_ name: String) async -> SyncResult {
        guard dependencies.cloud != nil else { return SyncResult(.off, "\(Self.offMessage); \(name) stays on this Mac") }
        return await exclusive { service in await service.runShare(name) }
    }

    public func deleteShared(_ name: String) async -> SyncResult {
        guard dependencies.cloud != nil else { return SyncResult(.failed, Self.offMessage) }
        return await exclusive { service in await service.runCommand { work, state, requests, changes in
            try await work.deleteShared(name, state: &state, requests: &requests, changes: &changes)
        } }
    }

    public func removeDevice(_ id: String) async -> SyncResult {
        guard dependencies.cloud != nil else { return SyncResult(.failed, Self.offMessage) }
        return await exclusive { service in await service.runCommand { work, state, requests, _ in
            try await work.removeDevice(id, state: &state, requests: &requests)
        } }
    }

    /// Stores the backup token on this Mac and seals it to every device, so one login serves every Mac.
    public func logInToBackup(token: Data, vault: String) async -> SyncResult {
        guard dependencies.cloud != nil else { return SyncResult(.off, Self.offMessage) }
        return await exclusive { service in await service.runLogInToBackup(token: token, vault: vault) }
    }

    /// Deletes the `Backup` record, which makes every Mac delete its token at its next check, and this Mac's token.
    public func logOutOfBackup() async -> SyncResult {
        guard dependencies.cloud != nil else {
            do {
                try dependencies.tokens.delete()
                return SyncResult(.done)
            } catch {
                return SyncResult(.failed, Display.clean(String(describing: error)))
            }
        }
        return await exclusive { service in await service.runCommand { work, state, requests, _ in
            try await work.logOutOfBackup(state: &state, requests: &requests)
        } }
    }

    public func devices() -> [DeviceSummary] {
        let me = (try? dependencies.device())?.recordName
        return state.devices.map { DeviceSummary(id: $0.key, name: $0.value.name, isThisDevice: $0.key == me) }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private func runShare(_ name: String) async -> SyncResult {
        // A share needs the devices and keys of the account, so a device that has not checked yet checks first.
        if state.databaseToken == nil || account == nil {
            _ = await runCheck(forced: false)
        }
        guard case .available? = account else {
            return SyncResult(.off, "\(state.lastMessage ?? "no iCloud account is available"); \(name) stays on this Mac")
        }
        return await runCommand { work, state, requests, _ in
            _ = try await work.share(name, state: &state, requests: &requests)
        }
    }

    private func runLogInToBackup(token: Data, vault: String) async -> SyncResult {
        // A login seals the token to the devices of the account, so a device that has not checked yet checks first.
        if state.databaseToken == nil || account == nil {
            _ = await runCheck(forced: false)
        }
        guard case .available? = account else {
            return SyncResult(.off, state.lastMessage ?? "no iCloud account is available")
        }
        return await runCommand { work, state, requests, _ in
            try await work.logInToBackup(token: token, vault: vault, state: &state, requests: &requests)
        }
    }

    private func runCommand(_ body: (SyncCheck, inout SyncState, inout Int, inout Changes) async throws -> Void) async -> SyncResult {
        var changes = Changes()
        do {
            guard let work = try await work() else { return SyncResult(.off, state.lastMessage ?? "no iCloud account is available") }
            var updated = state
            var requests = 0
            try await body(work, &updated, &requests, &changes)
            state = updated
            persist(force: true)
            await dependencies.onSharedKeysChanged()
            return SyncResult(.done)
        } catch {
            if !changes.isEmpty { await dependencies.onSharedKeysChanged() }
            return SyncResult(.failed, Display.clean(String(describing: error)))
        }
    }

    // MARK: Checks

    /// Runs `operation` after every check and command queued before it, so they never interleave.
    private func exclusive<Value: Sendable>(_ operation: @escaping @Sendable (isolated SyncService) async -> Value) async -> Value {
        let previous = tail
        let task = Task<Value, Never> {
            await previous?.value
            return await operation(self)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func check(forced: Bool) async -> CheckSummary {
        if let current, !forced { return await current.value }
        let task = Task { await self.exclusive { service in await service.runCheck(forced: forced) } }
        current = task
        return await task.value
    }

    /// The work for this device's account, or nil when no account is available. A new account removes the old one's shared keys.
    private func work() async throws -> SyncCheck? {
        guard let cloud = dependencies.cloud else { return nil }
        if account == nil || account != .available(user: state.user ?? "") {
            account = try await cloud.account()
        }
        guard case let .available(user)? = account else { return nil }
        let device = try dependencies.device()
        let work = SyncCheck(
            cloud: cloud, store: dependencies.store, device: device, deviceName: dependencies.deviceName(), version: dependencies.version,
            open: dependencies.open, tokens: dependencies.tokens, openSecret: dependencies.openSecret
        )
        if let old = state.user, old != user {
            var changes = Changes()
            try work.removeShared(changes: &changes)
            // The token belongs to the old account's backup.
            try dependencies.tokens.delete()
            state.forgetRecords()
            if !changes.isEmpty { await dependencies.onSharedKeysChanged() }
        }
        state.user = user
        return work
    }

    private func runCheck(forced: Bool) async -> CheckSummary {
        // The check ends here, so a request after this point starts a new one instead of joining this one's result.
        defer { current = nil }
        guard dependencies.cloud != nil else { return CheckSummary(outcome: .off, message: Self.offMessage) }
        if forced && state.isStopped {
            state.isStopped = false
            state.isPrepared = false
        }
        var requests = 0
        var changes = Changes()
        var outcome = CheckOutcome.ok
        var message: String?
        var retryAfter: TimeInterval?
        if state.isStopped {
            outcome = .stopped
            message = Self.stoppedMessage
        } else {
            do {
                if let work = try await work() {
                    state = try await work.run(from: state, requests: &requests, changes: &changes)
                    if state.isStopped {
                        outcome = .stopped
                        message = Self.stoppedMessage
                    } else if let unreadable = state.unreadable {
                        message = unreadable.count == 1
                            ? "1 record could not be read; the next check tries it again"
                            : "\(unreadable.count) records could not be read; the next check tries them again"
                    }
                } else {
                    outcome = .accountUnavailable
                    if case let .unavailable(reason)? = account { message = reason }
                }
            } catch let error as CloudError {
                message = error.message
                switch error.kind {
                case .throttled:
                    outcome = .throttled
                    retryAfter = error.retryAfter
                case .account:
                    account = nil
                    outcome = .accountUnavailable
                default:
                    outcome = .failed
                }
            } catch {
                outcome = .failed
                message = String(describing: error)
            }
        }

        let end = dependencies.now()
        let interval = dependencies.interval()
        let schedule = dependencies.schedule
        state.lastCheck = end
        state.lastResult = outcome
        state.lastMessage = message.map(Display.clean)
        state.requests = requests
        var delay: TimeInterval?
        switch outcome {
        case .ok:
            state.lastSuccess = end
            state.failures = 0
            delay = schedule.afterSuccess(interval: interval)
        case .failed:
            state.failures += 1
            delay = schedule.afterFailure(interval: interval, failures: state.failures)
        case .throttled:
            state.failures += 1
            delay = schedule.afterThrottle(interval: interval, retryAfter: retryAfter, failures: state.failures)
        case .accountUnavailable:
            state.failures = 0
            delay = SyncSchedule.accountRecheck
        case .stopped, .off:
            delay = nil
        }
        state.nextAttempt = delay.map { end.addingTimeInterval($0) }
        persist(force: false)
        if outcome != .ok, outcome != .accountUnavailable {
            let detail = state.lastMessage ?? ""
            log.notice("check \(outcome.rawValue, privacy: .public): \(detail, privacy: .public)")
        }
        if !changes.isEmpty { await dependencies.onSharedKeysChanged() }
        if let delay { startTimer(delay) }

        var summary = CheckSummary(outcome: outcome, message: state.lastMessage)
        summary.requests = requests
        summary.added = changes.added
        summary.replaced = changes.replaced
        summary.removed = changes.removed
        summary.sealed = changes.sealed
        summary.skipped = state.skipped.count
        return summary
    }

    // MARK: The state file

    /// Writes `sync.json` when something other than the check times changed, or every five minutes, so a check every 2 seconds writes nothing.
    private func persist(force: Bool) {
        var stable = state
        stable.lastCheck = nil
        stable.lastSuccess = nil
        stable.nextAttempt = nil
        stable.requests = 0
        let now = dependencies.now()
        if !force, stable == written, let at = writtenAt, now.timeIntervalSince(at) < 300 { return }
        var saved = state
        saved.lastPush = lastPush ?? state.lastPush
        do {
            try saved.save(to: dependencies.stateURL)
            written = stable
            writtenAt = now
        } catch {
            log.error("cannot write the sync state: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: The timer

    /// Starts the next check after `delay`, replacing a timer that has not fired. The check runs on its own task, so cancelling a timer never cancels a check.
    private func startTimer(_ delay: TimeInterval) {
        timer?.cancel()
        let sleep = dependencies.sleep
        timer = Task {
            do {
                try await sleep(delay)
            } catch {
                return
            }
            await self.fire()
        }
    }

    private func fire() async {
        guard !Task.isCancelled else { return }
        timer = nil
        _ = await check(forced: false)
    }
}
