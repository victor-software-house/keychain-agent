import AgentProtocol
@testable import AgentServer
import CryptoKit
import Foundation
@testable import Backup
@testable import KeyStore
import OnePassword
import SSHWire
import Synchronization
import Testing
@testable import Sync

// MARK: Fakes

/// A 1Password vault in memory, which records each call.
private final class FakeVault: BackupVault {
    private struct State {
        var items: [String: Item] = [:]
        var archived: Set<String> = []
        var calls: [String] = []
        var opened: [String] = []
        var unreadable: Set<String> = []
        var counter = 0
        var afterCreate: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    var calls: [String] { state.withLock { $0.calls } }
    var opened: [String] { state.withLock { $0.opened } }
    var items: [Item] { state.withLock { $0.items.values.sorted { ($0.title, $0.id) < ($1.title, $1.id) } } }

    func item(titled title: String) -> Item? { items.first { $0.title == title } }
    func recordOpen(_ vault: String) { state.withLock { $0.opened.append(vault) } }
    func resetCalls() { state.withLock { $0.calls = [] } }
    func failReads(of ids: Set<String>) { state.withLock { $0.unreadable = ids } }
    /// Runs `action` after the next create call, as another Mac's write that lands between two batches.
    func afterNextCreate(_ action: @escaping @Sendable () -> Void) { state.withLock { $0.afterCreate = action } }

    /// The item the vault stores for `content`, with the public key it derives from an SSH key field.
    private static func make(id: String, _ content: ItemContent, category: ItemCategory, updatedAt: Date) -> Item {
        let fields = content.fields.map { field -> Item.Field in
            guard field.type == .sshKey, case let .key(key, _)? = try? OpenSSHKeyFile.parse(field.value) else { return field }
            return Item.Field(
                id: field.id, title: field.title, type: field.type, value: field.value, sectionID: field.sectionID,
                publicKey: key.publicKey.openSSHLine(comment: "vault")
            )
        }
        return Item(
            id: id, title: content.title, category: category, vaultID: "vault", fields: fields, sections: content.sections, notes: content.notes,
            tags: content.tags, version: 1, updatedAt: updatedAt
        )
    }

    func list() async throws -> [ItemOverview] {
        state.withLock { state -> [ItemOverview] in
            state.calls.append("list")
            return state.items.values.sorted { $0.id < $1.id }.map { item in
                ItemOverview(
                    id: item.id, title: item.title, category: item.category, vaultID: item.vaultID, tags: item.tags, updatedAt: item.updatedAt,
                    state: state.archived.contains(item.id) ? .archived : .active
                )
            }
        }
    }

    func items(_ ids: [String]) async throws -> [ItemResult] {
        state.withLock { state -> [ItemResult] in
            state.calls.append("items:\(ids.count)")
            return ids.map { id -> ItemResult in
                if state.unreadable.contains(id) { return .failure(.internalError) }
                guard let item = state.items[id] else { return .failure(.notFound) }
                return .item(item)
            }
        }
    }

    func create(_ contents: [ItemContent]) async throws -> [ItemResult] {
        let (results, action) = state.withLock { state -> ([ItemResult], (@Sendable () -> Void)?) in
            state.calls.append("create:\(contents.count)")
            var results: [ItemResult] = []
            for content in contents {
                state.counter += 1
                let item = Self.make(id: "item-\(state.counter)", content, category: content.category, updatedAt: at(Double(state.counter)))
                state.items[item.id] = item
                results.append(.item(item))
            }
            let action = state.afterCreate
            state.afterCreate = nil
            return (results, action)
        }
        action?()
        return results
    }

    func put(_ id: String, _ content: ItemContent) async throws -> Item {
        try state.withLock { state throws -> Item in
            state.calls.append("put:\(id)")
            guard let old = state.items[id] else { throw BackupFailure("no item \(id)") }
            state.counter += 1
            let item = Self.make(id: id, content, category: old.category, updatedAt: at(Double(state.counter)))
            state.items[id] = item
            return item
        }
    }

    func delete(_ ids: [String]) async throws -> [String: ItemFailure] {
        state.withLock { state -> [String: ItemFailure] in
            state.calls.append("delete:\(ids.count)")
            for id in ids { state.items[id] = nil }
            return [:]
        }
    }

    func archive(_ id: String) async throws {
        state.withLock { state in
            state.calls.append("archive:\(id)")
            state.archived.insert(id)
        }
    }
}

/// One Mac with a backup token, over a fake iCloud, a fake vault and a fake clock.
private final class BackupRig: Sendable {
    let cloud = FakeCloud()
    let store = MemoryStore()
    let tokens = MemoryTokenStore()
    let vault = FakeVault()
    let clock = TestClock()
    let agreement = P256.KeyAgreement.PrivateKey()
    let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("backup-cache-\(UUID().uuidString).json")
    let device: DeviceKey
    let run: BackupRun

    init(removed: BackupRemoved = .delete) throws {
        let device = DeviceKey(handle: agreement.rawRepresentation, publicKey: agreement.publicKey.x963Representation)
        self.device = device
        let cloud = cloud
        let store = store
        let tokens = tokens
        let vault = vault
        let clock = clock
        try tokens.save(Data("ops_example-service-account-token".utf8))
        run = BackupRun(
            BackupRun.Dependencies(
                cloud: cloud, store: store, tokens: tokens, device: { device }, deviceName: { "mac-a" }, open: softwareOpen,
                openVault: { _, name in
                    vault.recordOpen(name)
                    return vault
                },
                removed: { removed }, now: { clock.now }, cacheURL: cacheURL
            )
        )
        cloud.put(.backup, BackupPayload.recordName, payload: Payload.encode(BackupPayload(vault: "signd", sealed: [:])))
    }

    deinit { try? FileManager.default.removeItem(at: cacheURL) }

    /// A shared key: in this Mac's store, and in a `Key` record.
    @discardableResult
    func share(_ name: String, hosts: [String] = []) throws -> PrivateKey {
        let (base, privateKey) = try localWrappedKey(name, hosts: hosts, comment: "\(name)@example")
        var stored = base
        stored.recordName = KeyPayload.recordName(for: name)
        try store.add(stored)
        publish(stored, hosts: hosts)
        return privateKey
    }

    /// Writes the `Key` record of `stored`, as another Mac does when it changes the key's hosts.
    func publish(_ stored: StoredKey, hosts: [String]) {
        let payload = KeyPayload(name: stored.name, comment: stored.comment, hosts: hosts, publicKey: stored.publicBlob, sealed: [:])
        cloud.put(.key, KeyPayload.recordName(for: stored.name), payload: Payload.encode(payload))
    }

    /// Deletes a shared key's record and this Mac's copy.
    func unshare(_ name: String) async throws {
        try await cloud.delete(.key, name: KeyPayload.recordName(for: name))
        try store.delete(name: name)
    }

    /// A key of this Mac only.
    func addLocal(_ name: String) throws {
        let (stored, _) = try localWrappedKey(name, comment: "\(name)@example")
        try store.add(stored)
    }

    /// Another Mac's claim on the lease.
    func holdLease(by holder: String, until expires: Date) {
        cloud.put(.lease, BackupLease.recordName, payload: Payload.encode(LeasePayload(holder: holder, expires: expires)))
    }

    func lease() throws -> LeasePayload {
        try Payload.decode(LeasePayload.self, from: try #require(cloud.record(BackupLease.recordName)).payload)
    }
}

// MARK: Schedule

@Test func aRunIsDueTheDelayAfterTheLastKeyChange() {
    let schedule = BackupSchedule()
    #expect(schedule.due(lastChange: at(1000), lastRun: at(-100_000)) == at(1300))
    #expect(schedule.wait(lastChange: at(1000), lastRun: at(-100_000), now: at(1100)) == 200)
    #expect(schedule.wait(lastChange: at(1000), lastRun: at(-100_000), now: at(5000)) == 0)
}

@Test func aRunIsDueAtMostOncePerInterval() {
    // The delay ends at 1300, but the last run began at 1000, and its interval ends at 4600.
    #expect(BackupSchedule().due(lastChange: at(1000), lastRun: at(1000)) == at(4600))
}

@Test func withNoChangeARunIsDueOncePerDayAndAMacThatNeverRanIsDueAtOnce() {
    let schedule = BackupSchedule()
    #expect(schedule.due(lastChange: nil, lastRun: at(0)) == at(86400))
    #expect(schedule.wait(lastChange: nil, lastRun: nil, now: at(0)) == 0)
}

@Test func theScheduleReadsTheThreeSettings() {
    #expect(BackupSchedule(settings: Settings(local: { _ in nil })) == BackupSchedule())
    let settings = Settings(local: { key in
        switch key {
        case .backupDelay: "10s"
        case .backupInterval: "2m"
        case .backupDailyInterval: "2h"
        default: nil
        }
    })
    #expect(BackupSchedule(settings: settings) == BackupSchedule(delay: 10, interval: 120, daily: 7200))
}

/// The backup service with a fake clock, a state file and runs that return the results in order.
private final class ServiceRig: Sendable {
    let clock = TestClock()
    let runs = Counter()
    let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("backup-state-\(UUID().uuidString).json")
    let service: BackupService

    init(state: BackupState, results: [BackupResult] = []) throws {
        try state.save(to: stateURL)
        let clock = clock
        let runs = runs
        let queue = Mutex(results)
        service = BackupService(
            BackupService.Dependencies(
                run: {
                    runs.increment()
                    return queue.withLock { $0.isEmpty ? BackupResult(.ok) : $0.removeFirst() }
                },
                schedule: { BackupSchedule() }, now: { clock.now }, sleep: { try await clock.sleep($0) }, stateURL: stateURL
            )
        )
    }

    deinit { try? FileManager.default.removeItem(at: stateURL) }
}

@Test(.timeLimit(.minutes(1))) func theServiceWaitsTheDelayAfterAKeyChangeAndTheDayWithNone() async throws {
    var state = BackupState()
    state.lastRun = at(-4000)
    let rig = try ServiceRig(state: state)
    await rig.service.start()
    // No change is waiting, so the next run is a day after the last.
    #expect(await eventually { rig.clock.requestedSleeps.contains(82400) })

    await rig.service.keysChanged()
    #expect(await eventually { rig.clock.requestedSleeps.contains(300) })
    #expect(await rig.service.snapshot().lastChange == at(0))
    #expect(rig.runs.value == 0)
}

@Test(.timeLimit(.minutes(1))) func aLocalKeyChangeMakesARunDueAfterTheDelay() async throws {
    var state = BackupState()
    state.lastRun = at(-4000)
    let rig = try ServiceRig(state: state)
    await rig.service.start()
    let service = rig.service
    // The command that imports, creates or deletes a key on this Mac asks the agent to reload, as the command line does.
    let server = Server(agent: await makeAgent(MemoryStore()), keysChanged: { await service.keysChanged() })
    let reload = Request.extension(name: PrivateExtension.reload, contents: Data())
    #expect(await server.respond(to: reload, on: Connection(peerPID: getpid())) == .success)

    #expect(await rig.service.snapshot().lastChange == at(0))
    #expect(await eventually { rig.clock.requestedSleeps.contains(300) })
    #expect(rig.runs.value == 0)
    // The delay ends 300 seconds after the change, and the interval since the last run ended long before.
    #expect(BackupSchedule().due(lastChange: at(0), lastRun: at(-4000)) == at(300))
}

@Test(.timeLimit(.minutes(1))) func aFailedRunRecordsItsErrorAndWaitsForTheNextSlot() async throws {
    var state = BackupState()
    state.lastRun = at(-100_000)
    let rig = try ServiceRig(state: state, results: [BackupResult(.failed, "boom")])
    // The last run is more than a day old, so the first run starts at once.
    await rig.service.start()
    #expect(await eventually { rig.clock.requestedSleeps.contains(3600) })
    #expect(rig.runs.value == 1)

    let failed = await rig.service.snapshot()
    #expect(failed.lastOutcome == .failed)
    #expect(failed.lastError == "boom")
    #expect(failed.lastRun == at(0))
    #expect(failed.lastSuccess == nil)
    #expect(failed.lastChange != nil)
    #expect(BackupState.load(from: rig.stateURL) == failed)

    // The slot comes an interval later, and the run after it ends the wait for a change.
    rig.clock.advance(3600)
    await rig.service.fire()
    #expect(rig.runs.value == 2)
    let done = await rig.service.snapshot()
    #expect(done.lastOutcome == .ok)
    #expect(done.lastError == nil)
    #expect(done.lastChange == nil)
    #expect(await eventually { rig.clock.requestedSleeps.contains(86400) })
}

// MARK: Lease

@Test(.timeLimit(.minutes(1))) func aLateClearLeavesAnotherMacsNewerClaim() async throws {
    let cloud = FakeCloud()
    let clock = TestClock()
    var first = BackupLease(cloud: cloud, holder: "device-a", now: { clock.now })
    var second = BackupLease(cloud: cloud, holder: "device-b", now: { clock.now })
    let firstClaim = try await first.claim()
    #expect(firstClaim == .acquired)
    // An unexpired claim blocks the other Mac.
    let early = try await second.claim()
    #expect(early == .held)

    // The first claim expires and the second Mac takes it over, so the first Mac's clear finds a newer claim.
    clock.advance(BackupLease.duration + 1)
    let takeover = try await second.claim()
    #expect(takeover == .acquired)
    await first.clear()
    let kept = try Payload.decode(LeasePayload.self, from: try #require(cloud.record(BackupLease.recordName)).payload)
    #expect(kept.holder == "device-b")
    #expect(kept.expires > clock.now)

    await second.clear()
    let cleared = try Payload.decode(LeasePayload.self, from: try #require(cloud.record(BackupLease.recordName)).payload)
    #expect(cleared.expires <= clock.now)
}

@Test(.timeLimit(.minutes(1))) func aLeaseHeldByAnotherMacStopsTheRunWithNoWrite() async throws {
    let rig = try BackupRig()
    try rig.share("work")
    rig.holdLease(by: "device-other", until: rig.clock.now.addingTimeInterval(300))
    let saves = rig.cloud.calls.save

    let result = await rig.run.perform()
    #expect(result.outcome == .held)
    #expect(rig.cloud.calls.save == saves)
    #expect(rig.cloud.calls.changes == 0)
    #expect(rig.vault.calls.isEmpty)
    #expect(rig.vault.opened.isEmpty)
    #expect(try rig.lease().holder == "device-other")
}

@Test(.timeLimit(.minutes(1))) func anExpiredLeaseIsTakenOver() async throws {
    let rig = try BackupRig()
    try rig.share("work")
    rig.holdLease(by: "device-other", until: rig.clock.now.addingTimeInterval(-1))

    let result = await rig.run.perform()
    #expect(result == BackupResult(.ok))
    #expect(rig.vault.items.map(\.title) == ["work"])
    // The run claimed the lease and cleared it again.
    let lease = try rig.lease()
    #expect(lease.holder == rig.device.recordName)
    #expect(lease.expires <= rig.clock.now)
}

@Test(.timeLimit(.minutes(1))) func aRenewalThatFailsMidRunStopsBeforeTheNextBatch() async throws {
    let rig = try BackupRig()
    // 101 new keys make two create batches, of 100 and 1.
    for number in 0..<101 { try rig.share(String(format: "key-%03d", number)) }
    let cloud = rig.cloud
    rig.vault.afterNextCreate {
        // Another Mac saves the lease between the batches, so this Mac's next renewal finds a newer change tag.
        cloud.put(.lease, BackupLease.recordName, payload: Payload.encode(LeasePayload(holder: "device-other", expires: at(100_000))))
    }

    let result = await rig.run.perform()
    #expect(result.outcome == .failed)
    #expect(result.message?.contains("lease was lost") == true)
    #expect(rig.vault.calls == ["list", "create:100"])
    #expect(rig.vault.items.count == 100)
    #expect(try rig.lease().holder == "device-other")
}

// MARK: Run

@Test(.timeLimit(.minutes(1))) func aRunCreatesUpdatesAndRemovesItemsAndSavesTheCache() async throws {
    let rig = try BackupRig()
    let alpha = try rig.share("alpha", hosts: ["a.example.com"])
    try rig.share("beta")
    try rig.addLocal("gamma")
    try rig.store.add(storedSoftwareKey("enclave"))

    let first = await rig.run.perform()
    #expect(first == BackupResult(.ok))
    #expect(rig.vault.opened == ["signd"])
    #expect(rig.vault.calls == ["list", "create:4"])
    #expect(rig.vault.items.map(\.title) == ["alpha", "beta", "gamma", "signd Secure Enclave keys (mac-a)"])
    // The item has a private key file that reads back as the shared key.
    let alphaItem = try #require(rig.vault.item(titled: "alpha"))
    let privateKeyField = alphaItem.fields.first { $0.title == "private key" }
    let field = try #require(privateKeyField)
    guard case let .key(parsed, _) = try OpenSSHKeyFile.parse(field.value) else {
        Issue.record("the item's private key field is not an unencrypted key file")
        return
    }
    #expect(parsed == alpha)
    #expect(try rig.lease().expires <= rig.clock.now)
    let cache = BackupCache.load(from: rig.cacheURL)
    #expect(cache.count == 4)
    for item in rig.vault.items { #expect(cache[item.id]?.updatedAt == item.updatedAt) }

    // A key changed its hosts, one was deleted, and one is new.
    let storedKeys = try rig.store.list()
    let stored = try #require(storedKeys.first { $0.name == "alpha" })
    rig.publish(stored, hosts: ["a.example.com", "b.example.com"])
    try await rig.unshare("beta")
    try rig.share("delta")
    let alphaID = alphaItem.id
    let beta = try #require(rig.vault.item(titled: "beta"))
    let betaID = beta.id
    rig.vault.resetCalls()

    let second = await rig.run.perform()
    #expect(second == BackupResult(.ok))
    // The cache is current, so the run reads no item.
    #expect(rig.vault.calls == ["list", "create:1", "put:\(alphaID)", "delete:1"])
    #expect(rig.vault.items.map(\.title) == ["alpha", "delta", "gamma", "signd Secure Enclave keys (mac-a)"])
    let hosts = rig.vault.item(titled: "alpha")?.fields.first { $0.title == "hosts" }
    #expect(hosts?.value == "a.example.com b.example.com")
    let updated = BackupCache.load(from: rig.cacheURL)
    #expect(updated.count == 4)
    #expect(updated[betaID] == nil)
    #expect(updated[alphaID]?.target == alphaID)
    for item in rig.vault.items { #expect(updated[item.id]?.updatedAt == item.updatedAt) }

    // Nothing changed, so the next run makes only the list call.
    rig.vault.resetCalls()
    #expect(await rig.run.perform() == BackupResult(.ok))
    #expect(rig.vault.calls == ["list"])
}

@Test(.timeLimit(.minutes(1))) func aFailedItemReadLeavesThatItemAloneAndCreatesNothing() async throws {
    let rig = try BackupRig()
    try rig.share("alpha")
    #expect(await rig.run.perform() == BackupResult(.ok))
    let alpha = try #require(rig.vault.item(titled: "alpha"))

    // Without the cache the next run reads every tagged item, and the read of alpha fails.
    try FileManager.default.removeItem(at: rig.cacheURL)
    try rig.share("beta")
    rig.vault.failReads(of: [alpha.id])
    rig.vault.resetCalls()

    let result = await rig.run.perform()
    #expect(result.outcome == .failed)
    #expect(result.message?.contains("could not be read") == true)
    #expect(rig.vault.calls == ["list", "items:1"])
    #expect(rig.vault.items == [alpha])
}
