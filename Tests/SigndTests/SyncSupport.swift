import CryptoKit
import Foundation
import KeyStore
import SSHWire
import Synchronization
@testable import Sync

/// A CloudKit stand-in: one private database with the `signd` zone, change tokens as sequence numbers and change tags as counters.
/// The test sets failures, delays and account changes.
final class FakeCloud: CloudStore {
    struct Calls: Equatable {
        var account = 0
        var prepare = 0
        var changes = 0
        var fetch = 0
        var save = 0
        var delete = 0
    }

    private struct Stored {
        var record: CloudRecord
        var tag: Int
        var sequence: Int
    }

    /// One account's private database.
    private struct Database {
        var records: [String: Stored] = [:]
        var deletions: [(name: String, sequence: Int)] = []
        var sequence = 0
        var loss: (kind: ZoneLoss, sequence: Int)?
        var zoneMissing = false
        /// Tokens older than this belong to a zone that is gone, so CloudKit reports them expired.
        var tokensFrom = 0
    }

    private struct State {
        var databases: [String: Database] = [:]
        var account = CloudAccount.available(user: "user-1")
        var failure: CloudError?
        var expireNextToken = false
        var saveFailure: CloudError?
        var beforeDelete: (@Sendable () -> Void)?
        var beforeSave: (@Sendable () -> Void)?
        var delay: Duration = .zero
        var calls = Calls()

        /// The signed-in account's database.
        var database: Database {
            get { databases[user] ?? Database() }
            set { databases[user] = newValue }
        }

        var user: String {
            if case let .available(user) = account { return user }
            return ""
        }
    }

    private let state = Mutex(State())

    var calls: Calls { state.withLock { $0.calls } }

    func fail(with error: CloudError?) { state.withLock { $0.failure = error } }
    /// Fails only saves, so a test can stop a command between its reads and its writes.
    func failSaves(with error: CloudError?) { state.withLock { $0.saveFailure = error } }
    /// Runs `action` before the next delete, as another device's write that lands while a command runs.
    func beforeNextDelete(_ action: @escaping @Sendable () -> Void) { state.withLock { $0.beforeDelete = action } }
    /// Runs `action` before the next save, as another device's write that lands between a command's read and its write.
    func beforeNextSave(_ action: @escaping @Sendable () -> Void) { state.withLock { $0.beforeSave = action } }
    func slow(_ delay: Duration) { state.withLock { $0.delay = delay } }
    func setAccount(_ account: CloudAccount) { state.withLock { $0.account = account } }
    func expireNextToken() { state.withLock { $0.expireNextToken = true } }

    /// The user deletes signd's data in iCloud settings: every record goes, and the next fetch reports the zone as deleted by the user.
    func deleteZoneByUser() {
        state.withLock { state in
            state.database.sequence += 1
            state.database.records = [:]
            state.database.deletions = []
            state.database.loss = (.deletedByUser, state.database.sequence)
        }
    }

    /// The zone goes with no notice to any device, as when CloudKit drops it: the next fetch reports it missing.
    func removeZone() {
        state.withLock { state in
            state.database.sequence += 1
            state.database.records = [:]
            state.database.deletions = []
            state.database.zoneMissing = true
            state.database.tokensFrom = state.database.sequence
        }
    }

    /// Saves a record as another signd would, with no check of its tag.
    func put(_ type: RecordType, _ name: String, payload: Data) {
        state.withLock { state in
            state.database.sequence += 1
            let tag = (state.database.records[name]?.tag ?? 0) + 1
            state.database.records[name] = Stored(record: CloudRecord(type: type, name: name, payload: payload), tag: tag, sequence: state.database.sequence)
        }
    }

    func record(_ name: String) -> CloudRecord? { state.withLock { $0.database.records[name]?.record } }

    private func answer<Value>(_ count: (inout Calls) -> Void, _ body: (inout State) throws(CloudError) -> Value) async throws(CloudError) -> Value {
        let delay = state.withLock { state -> Duration in
            count(&state.calls)
            return state.delay
        }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return try state.withLock { state throws(CloudError) -> Value in
            if let failure = state.failure { throw failure }
            return try body(&state)
        }
    }

    private static func token(_ sequence: Int) -> Data { Data(String(sequence).utf8) }
    private static func sequence(_ token: Data?) -> Int { token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? -1 }

    func account() async throws(CloudError) -> CloudAccount {
        try await answer({ $0.account += 1 }) { state throws(CloudError) in state.account }
    }

    func prepare() async throws(CloudError) {
        try await answer({ $0.prepare += 1 }) { state throws(CloudError) in
            state.database.loss = nil
            state.database.zoneMissing = false
        }
    }

    func changes(database: Data?, zone: Data?) async throws(CloudError) -> CloudChanges {
        try await answer({ $0.changes += 1 }) { state throws(CloudError) in
            if state.database.zoneMissing { throw CloudError(.zoneMissing, "the zone does not exist") }
            if state.expireNextToken, database != nil {
                state.expireNextToken = false
                throw CloudError(.tokenExpired, "the change token expired")
            }
            let since = Self.sequence(database)
            if database != nil, since < state.database.tokensFrom { throw CloudError(.tokenExpired, "the change token is from a zone that is gone") }
            let db = state.database
            var changes = CloudChanges()
            changes.requests = 1
            changes.databaseToken = Self.token(db.sequence)
            if let loss = db.loss, loss.sequence > since {
                changes.zoneLoss = loss.kind
                return changes
            }
            guard db.sequence > since || zone == nil else { return changes }
            changes.requests = 2
            changes.changed = db.records.values.filter { $0.sequence > since }.sorted { $0.sequence < $1.sequence }.map { stored in
                var record = stored.record
                record.system = Self.token(stored.tag)
                return record
            }
            changes.deleted = db.deletions.filter { $0.sequence > since }.map(\.name)
            changes.zoneToken = Self.token(db.sequence)
            return changes
        }
    }

    func fetch(_: RecordType, name: String) async throws(CloudError) -> CloudRecord? {
        try await answer({ $0.fetch += 1 }) { state throws(CloudError) in
            guard let stored = state.database.records[name] else { return nil }
            var record = stored.record
            record.system = Self.token(stored.tag)
            return record
        }
    }

    func save(_ record: CloudRecord) async throws(CloudError) -> CloudRecord {
        let action = state.withLock { state -> (@Sendable () -> Void)? in
            defer { state.beforeSave = nil }
            return state.beforeSave
        }
        action?()
        return try await answer({ $0.save += 1 }) { state throws(CloudError) in
            if let failure = state.saveFailure { throw failure }
            let existing = state.database.records[record.name]
            switch (existing, record.system) {
            case (nil, nil): break
            case let (existing?, system?) where existing.tag == Self.sequence(system): break
            default: throw CloudError(.conflict, "the record changed on the server")
            }
            state.database.sequence += 1
            let tag = (existing?.tag ?? 0) + 1
            var saved = record
            saved.system = nil
            state.database.records[record.name] = Stored(record: saved, tag: tag, sequence: state.database.sequence)
            saved.system = Self.token(tag)
            return saved
        }
    }

    func delete(_: RecordType, name: String) async throws(CloudError) {
        let action = state.withLock { state -> (@Sendable () -> Void)? in
            defer { state.beforeDelete = nil }
            return state.beforeDelete
        }
        action?()
        try await answer({ $0.delete += 1 }) { state throws(CloudError) in
            guard state.database.records.removeValue(forKey: name) != nil else { return }
            state.database.sequence += 1
            state.database.deletions.append((name, state.database.sequence))
        }
    }
}

/// The time of the `n`th second of a test.
func at(_ n: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + n) }

/// Opens a wrapped key whose `keyData` is a software P-256 key, in place of the Secure Enclave, which the runners lack.
let softwareOpen: KeyOpener = { key throws(SignError) in
    guard let wrapped = key.wrapped, let agreement = try? P256.KeyAgreement.PrivateKey(rawRepresentation: key.keyData) else {
        throw .invalidKey("\(key.name) is not a software wrapped key")
    }
    do {
        return try Wrapping.open(wrapped, publicBlob: key.publicBlob, with: agreement)
    } catch {
        throw .invalidKey("\(error)")
    }
}

/// Opens a sealed secret whose device handle is a software P-256 key, in place of the Secure Enclave.
let softwareOpenSecret: SecretOpener = { sealed, device in
    try Wrapping.open(sealed, with: P256.KeyAgreement.PrivateKey(rawRepresentation: device.handle))
}

/// An in-memory token store, for tests on runners that lack signd's keychain access group.
final class MemoryTokenStore: TokenStore {
    private let token = Mutex<Data?>(nil)

    func read() throws(StoreError) -> Data? { token.withLock { $0 } }
    func save(_ token: Data) throws(StoreError) { self.token.withLock { $0 = token } }
    func delete() throws(StoreError) { token.withLock { $0 = nil } }
}

/// A local wrapped key sealed to a software key, and its private key.
func localWrappedKey(_ name: String, hosts: [String] = [], comment: String = "") throws -> (StoredKey, PrivateKey) {
    let privateKey = memoryKey()
    let agreement = P256.KeyAgreement.PrivateKey()
    let wrapped = try Wrapping.seal(privateKey, comment: comment, to: agreement.publicKey)
    let key = StoredKey(
        name: name, kind: .wrapped, publicBlob: privateKey.publicKey.blob, comment: comment, hosts: hosts, source: "import",
        keyData: agreement.rawRepresentation, wrapped: wrapped
    )
    return (key, privateKey)
}

/// A clock and a sleep that the test drives: a sleep of zero returns at once, and any other is recorded and waits until cancelled.
final class TestClock: Sendable {
    private let time = Mutex(at(0))
    private let sleeps = Mutex<[TimeInterval]>([])

    var now: Date { time.withLock { $0 } }
    var requestedSleeps: [TimeInterval] { sleeps.withLock { $0 } }

    func advance(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }

    func sleep(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        sleeps.withLock { $0.append(seconds) }
        try await Task.sleep(for: .seconds(3600))
    }
}

/// Counts how often the agent was told to read the keys.
final class Counter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}

/// One device: a service over a shared `FakeCloud`, with its own store, software device key, clock and state file.
final class DeviceRig: Sendable {
    let cloud: FakeCloud?
    let store = MemoryStore()
    let tokens = MemoryTokenStore()
    let agreement = P256.KeyAgreement.PrivateKey()
    let clock = TestClock()
    let changes = Counter()
    let stateURL: URL
    let service: SyncService

    var device: DeviceKey { DeviceKey(handle: agreement.rawRepresentation, publicKey: agreement.publicKey.x963Representation) }

    init(cloud: FakeCloud?, name: String = "mac-a", random: Double = 0.5, interval: TimeInterval = 2) {
        self.cloud = cloud
        stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("sync-state-\(UUID().uuidString).json")
        let device = DeviceKey(handle: agreement.rawRepresentation, publicKey: agreement.publicKey.x963Representation)
        let clock = clock
        let changes = changes
        let tokens = tokens
        service = SyncService(
            SyncService.Dependencies(
                cloud: cloud, store: store, device: { device }, open: softwareOpen, tokens: tokens, openSecret: softwareOpenSecret, deviceName: { name }, version: "1.0.0",
                interval: { interval }, now: { clock.now }, sleep: { try await clock.sleep($0) },
                schedule: SyncSchedule(random: { random }), stateURL: stateURL, changed: { changes.increment() }
            )
        )
    }

    deinit { try? FileManager.default.removeItem(at: stateURL) }

    /// The keys this device serves from iCloud.
    func shared() throws -> [StoredKey] { try store.list().filter(\.isShared) }
}
