import CryptoKit
import Foundation
import KeyStore
import OnePassword
import SSHWire
import Synchronization
@testable import Sync

/// A 1Password stand-in that serves recorded vaults and items, counts its requests and can be slow or fail.
final class FakeSource: OnePasswordSource {
    struct Calls: Equatable {
        var vaults = 0
        var items = 0
        var item = 0
        var total: Int { vaults + items + item }
    }

    private struct State {
        var vaults: [VaultOverview] = []
        var overviews: [String: [ItemOverview]] = [:]
        var items: [String: Item] = [:]
        var calls = Calls()
        var failure: OnePasswordError?
        var itemFailures: [String: OnePasswordError] = [:]
        var delay: Duration = .zero
    }

    private let state = Mutex(State())

    var calls: Calls { state.withLock { $0.calls } }

    func resetCalls() { state.withLock { $0.calls = Calls() } }

    func fail(with error: OnePasswordError?) { state.withLock { $0.failure = error } }

    /// Makes one item's fetch fail, as an item the client cannot decode does.
    func failItem(_ id: String, with error: OnePasswordError?) { state.withLock { $0.itemFailures[id] = error } }

    func slow(_ delay: Duration) { state.withLock { $0.delay = delay } }

    func addVault(_ id: String) {
        state.withLock {
            $0.vaults.append(VaultOverview(id: id, title: id, contentVersion: 1, updatedAt: Date(timeIntervalSince1970: 0)))
            $0.overviews[id] = []
        }
    }

    /// Adds or replaces an item and raises its vault's content version, as 1Password does.
    func put(_ item: Item, category: String? = nil, state itemState: String = "active") {
        state.withLock { state in
            let overview = ItemOverview(
                id: item.id, title: item.title, category: category ?? item.category, vaultId: item.vaultId, updatedAt: item.updatedAt, state: itemState
            )
            state.overviews[item.vaultId, default: []].removeAll { $0.id == item.id }
            state.overviews[item.vaultId, default: []].append(overview)
            state.items[item.id] = item
            Self.bump(&state, vault: item.vaultId)
        }
    }

    func remove(itemID: String, vault: String) {
        state.withLock { state in
            state.overviews[vault]?.removeAll { $0.id == itemID }
            Self.bump(&state, vault: vault)
        }
    }

    private static func bump(_ state: inout State, vault: String) {
        guard let index = state.vaults.firstIndex(where: { $0.id == vault }) else { return }
        let old = state.vaults[index]
        state.vaults[index] = VaultOverview(id: old.id, title: old.title, contentVersion: old.contentVersion + 1, updatedAt: old.updatedAt)
    }

    private func answer<T: Sendable>(count: (inout Calls) -> Void, value: (State) -> T) async throws(OnePasswordError) -> T {
        let (result, failure, delay) = state.withLock { state -> (T, OnePasswordError?, Duration) in
            count(&state.calls)
            return (value(state), state.failure, state.delay)
        }
        if delay > .zero { try? await Task.sleep(for: delay) }
        if let failure { throw failure }
        return result
    }

    func vaults() async throws(OnePasswordError) -> [VaultOverview] {
        try await answer(count: { $0.vaults += 1 }, value: { $0.vaults })
    }

    func items(vaultID: String) async throws(OnePasswordError) -> [ItemOverview] {
        try await answer(count: { $0.items += 1 }, value: { $0.overviews[vaultID] ?? [] })
    }

    func item(vaultID _: String, itemID: String) async throws(OnePasswordError) -> Item {
        let found: Item? = try await answer(count: { $0.item += 1 }, value: { $0.items[itemID] })
        if let failure = state.withLock({ $0.itemFailures[itemID] }) { throw failure }
        guard let found else { throw OnePasswordError(kind: .other, message: "no such item") }
        return found
    }
}

/// The time of the `n`th second of a test.
func at(_ n: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + n) }

/// An Ed25519 key and its PKCS#8 file, as 1Password gives it.
func ed25519Key() -> (pem: String, key: PrivateKey) {
    let seed = Curve25519.Signing.PrivateKey()
    let der = Data([0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]) + seed.rawRepresentation
    let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
    let key = PrivateKey.ed25519(seed: seed.rawRepresentation, publicKey: seed.publicKey.rawRepresentation)
    return (String(decoding: armor("PRIVATE KEY", body), as: UTF8.self), key)
}

/// An SSH Key item.
func sshItem(
    _ id: String, title: String, vault: String = "v1", pem: String? = nil, hosts: String? = nil, macs: String? = nil, updated: Date = at(0)
) -> Item {
    var fields: [Item.Field] = [Item.Field(id: "private_key", title: "private key", fieldType: "SshKey", value: pem ?? ed25519Key().pem)]
    if let hosts { fields.append(Item.Field(id: "hosts", title: "hosts", fieldType: "Text", value: hosts)) }
    if let macs { fields.append(Item.Field(id: "macs", title: "macs", fieldType: "Text", value: macs)) }
    return Item(id: id, title: title, category: "SshKey", vaultId: vault, fields: fields, sections: [], notes: "", version: 1, updatedAt: updated)
}

/// The `signd` note.
func noteItem(_ id: String = "note", vault: String = "v1", interval: String? = nil, keyLifetime: String? = nil, updated: Date = at(0)) -> Item {
    var fields: [Item.Field] = []
    if let interval { fields.append(Item.Field(id: "interval", title: "interval", fieldType: "Text", value: interval)) }
    if let keyLifetime { fields.append(Item.Field(id: "key-lifetime", title: "key-lifetime", fieldType: "Text", value: keyLifetime)) }
    return Item(id: id, title: "signd", category: "SecureNote", vaultId: vault, fields: fields, sections: [], notes: "", version: 1, updatedAt: updated)
}

/// Seals keys to a software key in place of the Secure Enclave, which the runners lack.
let softwareWrapper: KeyWrapper = { name, key, comment, hosts throws(StoreError) in
    do {
        let recipient = P256.KeyAgreement.PrivateKey().publicKey
        let wrapped = try Wrapping.seal(key, comment: comment, to: recipient)
        return StoredKey(
            name: name, kind: .wrapped, publicBlob: key.publicKey.blob, comment: comment, hosts: hosts, source: StoredKey.syncedSource,
            keyData: Data(), wrapped: wrapped
        )
    } catch {
        throw .secureEnclave("\(error)")
    }
}

/// A clock and a sleep that the test drives: sleeps are recorded and wait until cancelled.
final class TestClock: Sendable {
    private let time = Mutex(at(0))
    private let sleeps = Mutex<[TimeInterval]>([])

    var now: Date { time.withLock { $0 } }
    var requestedSleeps: [TimeInterval] { sleeps.withLock { $0 } }

    func advance(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }

    func sleep(_ seconds: TimeInterval) async throws {
        sleeps.withLock { $0.append(seconds) }
        try await Task.sleep(for: .seconds(3600))
    }
}

/// The token the test's keychain holds.
final class TokenBox: Sendable {
    private let storage: Mutex<String?>
    private let deletes = Mutex(0)

    init(_ token: String?) { storage = Mutex(token) }

    var value: String? { storage.withLock { $0 } }
    var deleteCount: Int { deletes.withLock { $0 } }

    func set(_ token: String?) { storage.withLock { $0 = token } }

    func delete() {
        deletes.withLock { $0 += 1 }
        set(nil)
    }
}

/// A switch the test flips while a closure reads it.
final class Flag: Sendable {
    private let storage: Mutex<Bool>

    init(_ value: Bool) { storage = Mutex(value) }

    var value: Bool { storage.withLock { $0 } }

    func set(_ value: Bool) { storage.withLock { $0 = value } }
}

/// Counts how often the agent was told to read the keys.
final class Counter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}

/// A service over `source` with an in-memory store, a temporary state file and a clock the test drives.
struct SyncRig: ~Copyable {
    let source: FakeSource
    let store: MemoryStore
    let clock: TestClock
    let directory: TestDirectory
    let service: SyncService
    let changes: Counter
    let token: TokenBox

    var stateURL: URL { directory.url.appendingPathComponent("sync.json") }

    init(
        source: FakeSource, store: MemoryStore = MemoryStore(), token: String? = "token", random: Double = 0.5, hostName: String = "mac-a",
        version: String = "1.0.0", factory: SourceFactory? = nil, changed: (@Sendable () async -> Void)? = nil
    ) throws {
        self.source = source
        self.store = store
        let clock = TestClock()
        self.clock = clock
        let directory = try TestDirectory()
        let stateURL = directory.url.appendingPathComponent("sync.json")
        self.directory = directory
        let changes = Counter()
        self.changes = changes
        let box = TokenBox(token)
        self.token = box
        let make: SourceFactory = factory ?? { _ in source }
        service = SyncService(
            SyncService.Dependencies(
                token: { box.value }, deleteToken: { box.delete() }, makeSource: make, store: store, wrap: softwareWrapper, hostName: { hostName }, version: version,
                interval: { _ in 300 }, now: { clock.now }, sleep: { try await clock.sleep($0) },
                schedule: SyncSchedule(random: { random }), stateURL: stateURL,
                changed: {
                    changes.increment()
                    await changed?()
                }
            )
        )
    }

    func state() -> SyncState { SyncState.load(from: stateURL) }
}
