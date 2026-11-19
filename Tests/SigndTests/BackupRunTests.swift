import AgentProtocol
@testable import AgentServer
import CryptoKit
import Foundation
@testable import Backup
@testable import KeyStore
import OnePassword
import SSHEncoding
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
        var afterPut: (@Sendable () -> Void)?
        var failedWrites: Set<String> = []
        var reversed = false
        var writeError: (any Error)?
        var listError: (any Error)?
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
    /// Runs `action` after every put, as time that passes during a slow call, or another Mac's write.
    func afterPuts(_ action: @escaping @Sendable () -> Void) { state.withLock { $0.afterPut = action } }
    /// Makes each put and archive of these items throw.
    func failWrites(of ids: Set<String>, with error: (any Error)? = nil) {
        state.withLock {
            $0.failedWrites = ids
            $0.writeError = error
        }
    }
    /// Makes the list call throw `error`.
    func failList(with error: any Error) { state.withLock { $0.listError = error } }
    /// Returns the results of `items` and `create` in the reverse of the request order.
    func reverseResults() { state.withLock { $0.reversed = true } }

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
        try state.withLock { state throws -> [ItemOverview] in
            state.calls.append("list")
            if let error = state.listError { throw error }
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
            let results = ids.map { id -> ItemResult in
                if state.unreadable.contains(id) { return .failure(.internalError) }
                guard let item = state.items[id] else { return .failure(.notFound) }
                return .item(item)
            }
            return state.reversed ? results.reversed() : results
        }
    }

    func create(_ contents: [ItemContent]) async throws -> [ItemResult] {
        let (results, action, reversed) = state.withLock { state -> ([ItemResult], (@Sendable () -> Void)?, Bool) in
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
            return (results, action, state.reversed)
        }
        action?()
        return reversed ? results.reversed() : results
    }

    func put(_ id: String, _ content: ItemContent) async throws -> Item {
        let (item, action) = try state.withLock { state throws -> (Item, (@Sendable () -> Void)?) in
            state.calls.append("put:\(id)")
            if state.failedWrites.contains(id) { throw state.writeError ?? BackupFailure("the vault refused \(id)") }
            guard let old = state.items[id] else { throw BackupFailure("no item \(id)") }
            state.counter += 1
            let item = Self.make(id: id, content, category: old.category, updatedAt: at(Double(state.counter)))
            state.items[id] = item
            return (item, state.afterPut)
        }
        action?()
        return item
    }

    func delete(_ ids: [String]) async throws -> [String: ItemFailure] {
        state.withLock { state -> [String: ItemFailure] in
            state.calls.append("delete:\(ids.count)")
            for id in ids { state.items[id] = nil }
            return [:]
        }
    }

    func archive(_ id: String) async throws {
        try state.withLock { state throws in
            state.calls.append("archive:\(id)")
            if state.failedWrites.contains(id) { throw state.writeError ?? BackupFailure("the vault refused \(id)") }
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

    init(removed: BackupRemoval = .delete) throws {
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
                removal: { removed }, now: { clock.now }, cacheURL: cacheURL
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

    await rig.service.keysDidChange()
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
    let server = Server(agent: await makeAgent(MemoryStore()), onKeysChanged: { await service.keysDidChange() })
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

// MARK: Review fixes

/// The expiry of the lease record each time a put ends, so a test sees which renewals the run made.
private final class LeaseWatch: Sendable {
    private let seen = Mutex<[Date]>([])
    var expiries: [Date] { seen.withLock { $0 } }

    func record(_ cloud: FakeCloud) {
        guard let record = cloud.record(BackupLease.recordName), let lease = try? Payload.decode(LeasePayload.self, from: record.payload) else { return }
        seen.withLock { $0.append(lease.expires) }
    }
}

/// A rig that backed up three shared keys, and then saw their hosts change.
/// The next run puts three items in one group.
private func rigWithThreePuts() async throws -> BackupRig {
    let rig = try BackupRig()
    for name in ["alpha", "beta", "gamma"] { try rig.share(name) }
    #expect(await rig.run.perform() == BackupResult(.ok))
    for stored in try rig.store.list() { rig.publish(stored, hosts: ["h.example.com"]) }
    rig.vault.resetCalls()
    return rig
}

@Test(.timeLimit(.minutes(1))) func aKeyRecordWithAnotherPublicKeyGetsNoItemFromTheLocalKey() async throws {
    let rig = try BackupRig()
    try rig.share("alpha")
    let local = try #require(try rig.store.list().first)
    // Another Mac replaced the key: the record shows a new public key, and this Mac still has the old key under the name.
    let (replacement, _) = try localWrappedKey("alpha", comment: "alpha@example")
    rig.publish(replacement, hosts: [])

    #expect(await rig.run.perform() == BackupResult(.ok))
    #expect(rig.vault.calls == ["list"])
    #expect(rig.vault.items.isEmpty)
    #expect(BackupCache.load(from: rig.cacheURL).isEmpty)

    // The record shows the key this Mac has again, and the run writes its item.
    // It would not if the earlier run had cached the key as current.
    rig.publish(local, hosts: [])
    rig.vault.resetCalls()
    #expect(await rig.run.perform() == BackupResult(.ok))
    #expect(rig.vault.calls == ["list", "create:1"])
    #expect(rig.vault.items.map(\.title) == ["alpha"])
}

@Test(.timeLimit(.minutes(1))) func theLeaseIsRenewedBeforeACallOnceAThirdOfItHasPassed() async throws {
    let rig = try await rigWithThreePuts()
    let started = rig.clock.now
    let watch = LeaseWatch()
    let cloud = rig.cloud
    let clock = rig.clock
    rig.vault.afterPuts {
        watch.record(cloud)
        // Each put takes 240 seconds, longer than a third of the 600-second lease and shorter than half of it.
        clock.advance(240)
    }

    #expect(await rig.run.perform() == BackupResult(.ok))
    // The group's own renewal came first, and the second and third put each renewed again before the call.
    #expect(watch.expiries == [started.addingTimeInterval(600), started.addingTimeInterval(840), started.addingTimeInterval(1080)])
    #expect(rig.vault.items.allSatisfy { $0.fields.first { $0.title == "hosts" }?.value == "h.example.com" })
}

@Test(.timeLimit(.minutes(1))) func aRenewalThatFailsBeforeAPutStopsTheRunBeforeThatCall() async throws {
    let rig = try await rigWithThreePuts()
    let cloud = rig.cloud
    let clock = rig.clock
    rig.vault.afterPuts {
        // Another Mac takes the lease while the first put runs, and the put lasts longer than a third of the lease.
        cloud.put(.lease, BackupLease.recordName, payload: Payload.encode(LeasePayload(holder: "device-other", expires: at(100_000))))
        clock.advance(240)
    }

    let result = await rig.run.perform()
    #expect(result.outcome == .failed)
    #expect(result.message?.contains("lease was lost") == true)
    #expect(rig.vault.calls.count == 2)
    #expect(rig.vault.calls.last?.hasPrefix("put:") == true)
    #expect(try rig.lease().holder == "device-other")
}

@Test(.timeLimit(.minutes(1))) func aPutOrArchiveThatThrowsIsCountedAndTheRunGoesOn() async throws {
    let rig = try BackupRig(removed: .archive)
    for name in ["alpha", "beta", "gamma", "delta"] { try rig.share(name) }
    #expect(await rig.run.perform() == BackupResult(.ok))
    let alpha = try #require(rig.vault.item(titled: "alpha")).id
    let beta = try #require(rig.vault.item(titled: "beta")).id
    let gamma = try #require(rig.vault.item(titled: "gamma")).id
    let delta = try #require(rig.vault.item(titled: "delta")).id

    // Alpha and beta change their hosts, and gamma and delta go; the vault refuses the writes to alpha and gamma.
    for stored in try rig.store.list() where ["alpha", "beta"].contains(stored.name) { rig.publish(stored, hosts: ["h.example.com"]) }
    try await rig.unshare("gamma")
    try await rig.unshare("delta")
    rig.vault.failWrites(of: [alpha, gamma])
    rig.vault.resetCalls()

    let result = await rig.run.perform()
    #expect(result.outcome == .failed)
    #expect(result.message?.contains("writes the vault rejected: 2") == true)
    #expect(Set(rig.vault.calls) == ["list", "put:\(alpha)", "put:\(beta)", "archive:\(gamma)", "archive:\(delta)"])
    #expect(rig.vault.item(titled: "beta")?.fields.first { $0.title == "hosts" }?.value == "h.example.com")
    #expect(try rig.lease().expires <= rig.clock.now)
}

/// A lease payload of the given format that carries the fields of format 1.
private func leasePayload(format: Int, expires: Date) -> Data {
    Data(#"{"expires":\#(expires.timeIntervalSinceReferenceDate),"format":\#(format),"holder":"device-other"}"#.utf8)
}

@Test(.timeLimit(.minutes(1))) func aLeaseOfAnotherFormatHoldsUntilItsExpiryAndOnlyAnUnreadableOneIsFree() async throws {
    let held = try BackupRig()
    try held.share("work")
    held.cloud.put(.lease, BackupLease.recordName, payload: leasePayload(format: 2, expires: held.clock.now.addingTimeInterval(300)))
    let saves = held.cloud.calls.save
    #expect(await held.run.perform().outcome == .held)
    #expect(held.cloud.calls.save == saves)
    #expect(held.vault.calls.isEmpty)

    let expired = try BackupRig()
    try expired.share("work")
    expired.cloud.put(.lease, BackupLease.recordName, payload: leasePayload(format: 2, expires: expired.clock.now.addingTimeInterval(-1)))
    #expect(await expired.run.perform() == BackupResult(.ok))
    #expect(expired.vault.items.map(\.title) == ["work"])

    let unreadable = try BackupRig()
    try unreadable.share("work")
    unreadable.cloud.put(.lease, BackupLease.recordName, payload: Data("not a lease".utf8))
    #expect(await unreadable.run.perform() == BackupResult(.ok))
    #expect(unreadable.vault.items.map(\.title) == ["work"])
}

@Test(.timeLimit(.minutes(1))) func resultsAreMatchedToTheirRequestsWhateverTheOrder() async throws {
    let rig = try BackupRig()
    rig.vault.reverseResults()
    for name in ["alpha", "beta", "gamma"] { try rig.share(name) }

    #expect(await rig.run.perform() == BackupResult(.ok))
    #expect(rig.vault.items.map(\.title) == ["alpha", "beta", "gamma"])
    // Each created item is cached with the source of its own key, so the next run finds every item current and writes nothing.
    rig.vault.resetCalls()
    #expect(await rig.run.perform() == BackupResult(.ok))
    #expect(rig.vault.calls == ["list"])

    // Without the cache every item is read, and the read of one fails: that item is the unread one, whatever the order of the results.
    try FileManager.default.removeItem(at: rig.cacheURL)
    let alpha = try #require(rig.vault.item(titled: "alpha"))
    rig.vault.failReads(of: [alpha.id])
    rig.vault.resetCalls()
    let result = await rig.run.perform()
    #expect(result.outcome == .failed)
    #expect(result.message?.contains("1 of the vault's items could not be read") == true)
    #expect(rig.vault.calls == ["list", "items:3"])
    #expect(rig.vault.items.count == 3)
}

// MARK: Keys the SSH Key item cannot take, and 1Password errors

/// A wrapped key of this Mac, sealed to a software key, for any key type.
private func wrappedKey(_ name: String, _ privateKey: PrivateKey) throws -> StoredKey {
    let agreement = P256.KeyAgreement.PrivateKey()
    let wrapped = try Wrapping.seal(privateKey, comment: "\(name)@example", to: agreement.publicKey)
    return StoredKey(
        name: name, kind: .wrapped, publicBlob: privateKey.publicKey.blob, comment: "\(name)@example", hosts: [], source: "import",
        keyData: agreement.rawRepresentation, wrapped: wrapped
    )
}

@Test func anSSHKeyItemSupportsEd25519AndRSAOfTheListedSizesAndExponents() {
    func rsa(bits: Int, exponent: [UInt8] = [1, 0, 1], leadingZero: Bool = false) -> PublicKey {
        .rsa(exponent: Data(exponent), modulus: Data(leadingZero ? [0] : []) + Data([0x80]) + Data(repeating: 1, count: bits / 8 - 1))
    }
    let item = ItemCategory.sshKey
    #expect(item.supports(.ed25519(Data(repeating: 1, count: 32))))
    for bits in [2048, 3072, 4096] {
        #expect(item.supports(rsa(bits: bits)))
        #expect(item.supports(rsa(bits: bits, leadingZero: true)))
    }
    for bits in [1024, 1536, 2560, 8192] { #expect(!item.supports(rsa(bits: bits))) }
    #expect(item.supports(rsa(bits: 2048, exponent: [1, 0, 0, 0, 1])))
    #expect(!item.supports(rsa(bits: 2048, exponent: [3])))
    #expect(!item.supports(rsa(bits: 2048, exponent: [0xFF, 0xFF])))
    let point = P256.Signing.PrivateKey().publicKey.x963Representation
    for curve in Curve.allCases { #expect(!item.supports(.ecdsa(curve, point))) }
}

@Test func aSecureNoteSupportsEveryKeyAndNoOtherCategoryDoes() {
    let point = P256.Signing.PrivateKey().publicKey.x963Representation
    let keys: [PublicKey] = [
        .ed25519(Data(repeating: 1, count: 32)), .ecdsa(.p256, point),
        .rsa(exponent: Data([1, 0, 1]), modulus: Data([0x80]) + Data(repeating: 1, count: 127)),
    ]
    for key in keys {
        #expect(ItemCategory.secureNote.supports(key))
        for other in [ItemCategory.login, .password, .document, .apiCredentials] { #expect(!other.supports(key)) }
    }
}

@Test(.timeLimit(.minutes(1))) func aKeyTheSSHKeyItemCannotTakeGetsASecureNote() async throws {
    let rig = try BackupRig()
    try rig.share("good")
    let signing = P256.Signing.PrivateKey()
    let ecdsa = PrivateKey.ecdsa(.p256, point: signing.publicKey.x963Representation, scalar: signing.rawRepresentation)
    // The numbers of a Rivest-Shamir-Adleman (RSA) key are fillers: only its size matters.
    func rsa(bytes: Int) -> PrivateKey {
        let filler = Data([0x80]) + Data(repeating: 1, count: bytes - 1)
        return .rsa(n: filler, e: Data([1, 0, 1]), d: filler, iqmp: filler, p: filler, q: filler)
    }

    // The elliptic curve key is shared, so its record exists, and the other keys are this Mac's own.
    var shared = try wrappedKey("ecdsa-shared", ecdsa)
    shared.recordName = KeyPayload.recordName(for: shared.name)
    try rig.store.add(shared)
    rig.publish(shared, hosts: [])
    try rig.store.add(wrappedKey("rsa-1024", rsa(bytes: 128)))
    try rig.store.add(wrappedKey("rsa-2048", rsa(bytes: 256)))

    #expect(await rig.run.perform() == BackupResult(.ok))
    #expect(rig.vault.calls == ["list", "create:4"])
    #expect(Dictionary(uniqueKeysWithValues: rig.vault.items.map { ($0.title, $0.category) }) == [
        "good": .sshKey, "rsa-2048": .sshKey, "ecdsa-shared": .secureNote, "rsa-1024": .secureNote,
    ])
    let note = try #require(rig.vault.item(titled: "ecdsa-shared"))
    let fields = Dictionary(uniqueKeysWithValues: note.fields.map { ($0.title, $0) })
    #expect(fields["private key"]?.type == .concealed)
    #expect(fields["private key"]?.value.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") == true)
    #expect(fields["public key"]?.type == .text)
    #expect(fields["public key"]?.value == ecdsa.publicKey.openSSHLine(comment: "ecdsa-shared@example"))
    #expect(fields["comment"]?.value == "ecdsa-shared@example")
    #expect(fields["kind"]?.value == "key" && fields["scope"]?.value == BackupFormat.shared)
    #expect(note.tags == [BackupFormat.tag])

    // The notes are current: the cache spares their reads, and without it each is read and left alone.
    rig.vault.resetCalls()
    #expect(await rig.run.perform() == BackupResult(.ok))
    #expect(rig.vault.calls == ["list"])
    try FileManager.default.removeItem(at: rig.cacheURL)
    rig.vault.resetCalls()
    #expect(await rig.run.perform() == BackupResult(.ok))
    #expect(rig.vault.calls == ["list", "items:4"])
}

@Test(.timeLimit(.minutes(1))) func aOnePasswordErrorIsRecordedByItsKindAndNeverItsMessage() async throws {
    let rig = try BackupRig()
    try rig.share("alpha")
    #expect(await rig.run.perform() == BackupResult(.ok))
    let alpha = try #require(rig.vault.item(titled: "alpha"))
    let privateKey = try #require(alpha.fields.first { $0.title == "private key" }).value
    let echo = OnePasswordError(code: .requestFailed, message: "invalid field \(privateKey) and hosts h.example.com")

    // A write fails with an error that echoes the item's fields: the result names the call, the item and the error code.
    for stored in try rig.store.list() { rig.publish(stored, hosts: ["h.example.com"]) }
    rig.vault.failWrites(of: [alpha.id], with: echo)
    let write = await rig.run.perform()
    #expect(write.outcome == .failed)
    #expect(write.message == "writes the vault rejected: 1 (put \(alpha.id): 1Password requestFailed)")

    // A call that stops the run records the error code alone.
    rig.vault.failList(with: echo)
    let stopped = await rig.run.perform()
    #expect(stopped == BackupResult(.failed, "1Password requestFailed"))
    for message in [write.message, stopped.message].compactMap({ $0 }) {
        #expect(!message.contains("h.example.com"))
        for line in privateKey.split(separator: "\n") where line.count > 20 { #expect(!message.contains(line)) }
    }
}
