import AgentProtocol
@testable import AgentServer
import Foundation
import KeyStore
import OnePassword
import SSHWire
import Synchronization
import Testing
@testable import Sync

/// Waits until `condition` holds, for up to `seconds`.
func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

func oneVault(_ items: Item...) -> FakeSource {
    let source = FakeSource()
    source.addVault("v1")
    for item in items { source.put(item) }
    return source
}

@Suite struct SelectionRules {
    @Test func namesAreLowercaseWithOtherCharactersTurnedIntoDashes() {
        #expect(Selection.keyName(forTitle: "Deploy Key (prod)") == "deploy-key--prod-")
        #expect(Selection.keyName(forTitle: "ci_runner-2") == "ci_runner-2")
        #expect(Selection.keyName(forTitle: "Zürich.key") == "z-rich-key")
    }

    @Test func aTitleWithNoUsableNameIsSkipped() {
        guard case let .skipped(kind, _) = Selection.read(sshItem("i", title: ""), hostName: "mac-a") else {
            Issue.record("an empty title was accepted")
            return
        }
        #expect(kind == .invalidName)
    }

    @Test func aProtectedOrMissingKeyIsSkipped() {
        let missing = Item(id: "i", title: "k", category: "SshKey", vaultId: "v1", fields: [], sections: [], notes: "", version: 1, updatedAt: at(0))
        guard case let .skipped(kind, _) = Selection.read(missing, hostName: "mac-a") else {
            Issue.record("an item with no key was accepted")
            return
        }
        #expect(kind == .invalidKey)
        guard case let .skipped(garbage, _) = Selection.read(sshItem("i", title: "k", pem: "not a key"), hostName: "mac-a") else {
            Issue.record("a garbage key was accepted")
            return
        }
        #expect(garbage == .invalidKey)
    }
}

@Suite struct Checks {
    @Test func addsAKeyFromAnSSHKeyItem() async throws {
        let (pem, key) = ed25519Key()
        let rig = try SyncRig(source: oneVault(sshItem("i1", title: "Deploy Key", pem: pem, hosts: "git.example.com, other.example.com")))
        await rig.service.start()
        let summary = await rig.service.checkNow()
        #expect(summary.outcome == .ok)
        #expect(summary.added == ["deploy-key"])
        #expect(summary.requests == 3)
        #expect(summary.fetched == 1)
        let stored = try #require(try rig.store.list().first)
        #expect(stored.hosts == ["git.example.com", "other.example.com"])
        #expect(stored.source == "1password")
        #expect(stored.publicBlob == key.publicKey.blob)
        #expect(stored.vaultID == "v1")
        #expect(stored.itemID == "i1")
        #expect(rig.changes.value == 1)
    }

    @Test func aChangedKeyReplacesTheStoredOneInPlace() async throws {
        let rig = try SyncRig(source: oneVault(sshItem("i1", title: "deploy")))
        await rig.service.start()
        _ = await rig.service.checkNow()
        let before = try #require(try rig.store.list().first)
        let (pem, key) = ed25519Key()
        rig.source.put(sshItem("i1", title: "deploy", pem: pem, updated: at(10)))
        rig.source.resetCalls()
        let summary = await rig.service.checkNow()
        #expect(summary.replaced == ["deploy"])
        #expect(summary.requests == 3)
        let after = try rig.store.list()
        #expect(after.count == 1)
        #expect(after.first?.publicBlob == key.publicKey.blob)
        #expect(after.first?.publicBlob != before.publicBlob)
        #expect(after.first?.itemUpdated == at(10))
    }

    @Test func aChangeOfHostsKeepsTheSealedKey() async throws {
        let (pem, _) = ed25519Key()
        let rig = try SyncRig(source: oneVault(sshItem("i1", title: "deploy", pem: pem, hosts: "a.example.com")))
        await rig.service.start()
        _ = await rig.service.checkNow()
        let before = try #require(try rig.store.list().first)
        rig.source.put(sshItem("i1", title: "deploy", pem: pem, hosts: "b.example.com", updated: at(10)))
        let summary = await rig.service.checkNow()
        #expect(summary.replaced == ["deploy"])
        let after = try #require(try rig.store.list().first)
        #expect(after.hosts == ["b.example.com"])
        #expect(after.wrapped == before.wrapped)
    }

    @Test func aRenamedItemReplacesItsOldName() async throws {
        let (pem, _) = ed25519Key()
        let rig = try SyncRig(source: oneVault(sshItem("i1", title: "old", pem: pem)))
        await rig.service.start()
        _ = await rig.service.checkNow()
        rig.source.put(sshItem("i1", title: "New", pem: pem, updated: at(10)))
        _ = await rig.service.checkNow()
        #expect(try rig.store.list().map(\.name) == ["new"])
    }

    @Test func aDeletedItemRemovesItsKey() async throws {
        let rig = try SyncRig(source: oneVault(sshItem("i1", title: "deploy"), sshItem("i2", title: "other")))
        await rig.service.start()
        _ = await rig.service.checkNow()
        rig.source.remove(itemID: "i1", vault: "v1")
        let summary = await rig.service.checkNow()
        #expect(summary.removed == ["deploy"])
        #expect(try rig.store.list().map(\.name) == ["other"])
    }

    @Test func anArchivedItemCountsAsDeleted() async throws {
        let item = sshItem("i1", title: "deploy")
        let rig = try SyncRig(source: oneVault(item))
        await rig.service.start()
        _ = await rig.service.checkNow()
        rig.source.put(item, state: "archived")
        _ = await rig.service.checkNow()
        #expect(try rig.store.list().isEmpty)
    }

    @Test func aDeletedVaultRemovesItsKeys() async throws {
        let source = oneVault(sshItem("i1", title: "deploy"))
        let rig = try SyncRig(source: source)
        await rig.service.start()
        _ = await rig.service.checkNow()
        let empty = FakeSource()
        let second = try SyncRig(source: empty, store: rig.store)
        await second.service.start()
        _ = await second.service.checkNow()
        #expect(try rig.store.list().isEmpty)
    }

    @Test func nothingChangedCostsOneRequest() async throws {
        let rig = try SyncRig(source: oneVault(sshItem("i1", title: "deploy")))
        await rig.service.start()
        _ = await rig.service.checkNow()
        rig.source.resetCalls()
        let summary = await rig.service.checkNow()
        #expect(summary.outcome == .ok)
        #expect(summary.requests == 1)
        #expect(summary.fetched == 0)
        #expect(rig.source.calls == FakeSource.Calls(vaults: 1, items: 0, item: 0))
        #expect(rig.changes.value == 1)
    }

    @Test func theMacsFieldLimitsWhichMacsTakeAKey() async throws {
        let rig = try SyncRig(source: oneVault(
            sshItem("i1", title: "mine", macs: "Mac-B, MAC-A"),
            sshItem("i2", title: "theirs", macs: "mac-b mac-c"),
            sshItem("i3", title: "everyone")
        ))
        await rig.service.start()
        _ = await rig.service.checkNow()
        #expect(try rig.store.list().map(\.name) == ["everyone", "mine"])
        let status = SyncStatus(signedIn: true, state: rig.state())
        #expect(status.skipped.isEmpty)

        rig.source.put(sshItem("i2", title: "theirs", macs: "mac-a", updated: at(10)))
        _ = await rig.service.checkNow()
        #expect(try rig.store.list().map(\.name) == ["everyone", "mine", "theirs"])
    }

    @Test func aKeyLimitedToOtherMacsLeavesWhenItsMacsChange() async throws {
        let rig = try SyncRig(source: oneVault(sshItem("i1", title: "deploy")))
        await rig.service.start()
        _ = await rig.service.checkNow()
        rig.source.put(sshItem("i1", title: "deploy", macs: "mac-b", updated: at(10)))
        _ = await rig.service.checkNow()
        #expect(try rig.store.list().isEmpty)
    }

    @Test func aBadHostSkipsTheItemAndNamesIt() async throws {
        let rig = try SyncRig(source: oneVault(sshItem("i1", title: "deploy", hosts: "example.com ProxyCommand x")))
        await rig.service.start()
        let summary = await rig.service.checkNow()
        #expect(summary.skipped == 1)
        #expect(try rig.store.list().isEmpty)
        let skipped = try #require(SyncStatus(signedIn: true, state: rig.state()).skipped.first)
        #expect(skipped.item == "deploy")
        #expect(skipped.reason.contains("example.com ProxyCommand x"))
    }

    @Test func aNameTakenByALocalKeyIsSkippedAndReported() async throws {
        let store = MemoryStore()
        var local = storedSoftwareKey("deploy")
        local.source = "local"
        try store.add(local)
        let rig = try SyncRig(source: oneVault(sshItem("i1", title: "Deploy")), store: store)
        await rig.service.start()
        let summary = await rig.service.checkNow()
        #expect(summary.skipped == 1)
        #expect(try store.list() == [local])
    }

    @Test func theNoteSetsFleetSettings() async throws {
        let rig = try SyncRig(source: oneVault(sshItem("i1", title: "deploy"), noteItem(interval: "60m", keyLifetime: "soon")))
        await rig.service.start()
        _ = await rig.service.checkNow()
        #expect(rig.service.fleet.values == ["interval": "60m"])
        let status = SyncStatus(signedIn: true, state: rig.state())
        let local = Settings().value(.interval)
        #expect(status.interval.source == (local == nil ? .note : .local))
        #expect(status.interval.value == (local ?? "60m"))
        #expect(status.skipped.map(\.item) == ["signd note"])
        #expect(try rig.store.list().map(\.name) == ["deploy"])
    }

    @Test func statusJSONCarriesTheLastResultTheNextAttemptAndEverySkippedItem() async throws {
        let rig = try SyncRig(source: oneVault(
            sshItem("i1", title: "deploy"), sshItem("i2", title: "bad", hosts: "a b"), sshItem("i3", title: "worse", hosts: "c;d")
        ))
        await rig.service.start()
        _ = await rig.service.checkNow()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(SyncStatus(signedIn: true, state: rig.state()))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["signedIn"] as? Bool == true)
        #expect(json["lastResult"] as? String == "ok")
        #expect(json["nextAttempt"] as? String != nil)
        #expect(json["requests"] as? Int == 5)
        #expect((json["skipped"] as? [[String: Any]])?.map { $0["item"] as? String } == ["bad", "worse"])
        let interval = try #require(json["interval"] as? [String: Any])
        #expect(interval["source"] as? String != nil)
        #expect(!String(decoding: data, as: UTF8.self).contains("token"))
    }

    @Test func aLocalSettingWinsOverTheNote() {
        #expect(Settings().resolve(.keyLifetime, fleet: ["key-lifetime": "2h"]).source == (Settings().value(.keyLifetime) == nil ? .note : .local))
        #expect(Settings().resolve(.interval, fleet: ["interval": "0s"]).source != .note)
    }

    @Test func theDefaultIntervalIsFiveMinutes() {
        let resolved = Settings().resolve(.interval)
        if Settings().value(.interval) == nil {
            #expect(resolved.seconds == 300)
            #expect(resolved.source == .default)
        }
    }

    @Test func theStateFileHoldsNoToken() async throws {
        let rig = try SyncRig(source: oneVault(sshItem("i1", title: "deploy")), token: "ops_secret-token-value")
        await rig.service.start()
        _ = await rig.service.checkNow()
        let text = try String(contentsOf: rig.stateURL, encoding: .utf8)
        #expect(!text.contains("ops_secret-token-value"))
    }

    @Test func withoutATokenACheckSaysSo() async throws {
        let rig = try SyncRig(source: oneVault(), token: nil)
        await rig.service.start()
        #expect(await rig.service.checkNow().outcome == .notSignedIn)
        #expect(rig.source.calls.total == 0)
    }

    @Test func storedKeysSurviveAnUnreachableOnePassword() async throws {
        let rig = try SyncRig(source: oneVault(sshItem("i1", title: "deploy")))
        await rig.service.start()
        _ = await rig.service.checkNow()
        rig.source.fail(with: OnePasswordError(kind: .other, message: "offline"))
        let summary = await rig.service.checkNow()
        #expect(summary.outcome == .failed)
        #expect(summary.message == "offline")
        #expect(try rig.store.list().map(\.name) == ["deploy"])
        #expect(rig.state().lastResult == .failed)
    }
}

@Suite struct Schedule {
    @Test func theFirstWaitIsARandomPointWithinTheInterval() {
        #expect(SyncSchedule(random: { 0 }).phase(interval: 300) == 0)
        #expect(SyncSchedule(random: { 0.5 }).phase(interval: 300) == 150)
        #expect(SyncSchedule(random: { 0.999 }).phase(interval: 300) < 300)
    }

    @Test func eachWaitAfterASuccessIsTheIntervalTimesZeroPointEightToOnePointTwo() {
        #expect(SyncSchedule(random: { 0 }).afterSuccess(interval: 300) == 240)
        #expect(SyncSchedule(random: { 0.5 }).afterSuccess(interval: 300) == 300)
        #expect(SyncSchedule(random: { 0.999 }).afterSuccess(interval: 300) < 360)
    }

    @Test func aFailureWaitsUpToSixtySecondsTimesTwoToTheAttemptCappedByTheInterval() {
        let schedule = SyncSchedule(random: { 1 })
        #expect(schedule.afterFailure(interval: 300, failures: 1) == 60)
        #expect(schedule.afterFailure(interval: 300, failures: 2) == 120)
        #expect(schedule.afterFailure(interval: 300, failures: 3) == 240)
        #expect(schedule.afterFailure(interval: 300, failures: 4) == 300)
        #expect(schedule.afterFailure(interval: 300, failures: 100) == 300)
        #expect(SyncSchedule(random: { 0 }).afterFailure(interval: 300, failures: 3) == 0)
    }

    @Test func aRateLimitWaitsAnHourPlusJitterDoublingUpToADay() {
        #expect(SyncSchedule(random: { 0 }).afterRateLimit(repeats: 1) == 3600)
        #expect(SyncSchedule(random: { 1 }).afterRateLimit(repeats: 1) == 4200)
        #expect(SyncSchedule(random: { 0 }).afterRateLimit(repeats: 2) == 7200)
        #expect(SyncSchedule(random: { 0 }).afterRateLimit(repeats: 4) == 28800)
        #expect(SyncSchedule(random: { 1 }).afterRateLimit(repeats: 20) == 86400)
    }

    @Test func theServiceWaitsARandomPhaseThenTheIntervalAfterEachSuccess() async throws {
        let rig = try SyncRig(source: oneVault(), random: 0.5)
        await rig.service.start()
        #expect(await eventually { rig.clock.requestedSleeps == [150] })
        #expect(rig.state().nextAttempt == at(150))
        rig.clock.advance(150)
        let summary = await rig.service.checkNow()
        #expect(summary.outcome == .ok)
        #expect(rig.state().nextAttempt == at(450))
        #expect(await eventually { rig.clock.requestedSleeps == [150, 300] })
    }

    @Test func failuresBackOffWithFullJitter() async throws {
        let rig = try SyncRig(source: oneVault(), random: 1)
        rig.source.fail(with: OnePasswordError(kind: .other, message: "offline"))
        await rig.service.start()
        var waits: [TimeInterval] = []
        for _ in 0..<5 {
            _ = await rig.service.checkNow()
            let next = try #require(rig.state().nextAttempt)
            waits.append(next.timeIntervalSince(rig.clock.now))
        }
        #expect(waits == [60, 120, 240, 300, 300])
        rig.source.fail(with: nil)
        #expect(await rig.service.checkNow().outcome == .ok)
        #expect(rig.state().failures == 0)
    }

    @Test func aRateLimitWaitsAtLeastAnHourAndGrows() async throws {
        let rig = try SyncRig(source: oneVault(), random: 0)
        rig.source.fail(with: OnePasswordError(kind: .rateLimited, message: "429"))
        await rig.service.start()
        var waits: [TimeInterval] = []
        for _ in 0..<3 {
            let summary = await rig.service.checkNow()
            #expect(summary.outcome == .rateLimited)
            waits.append(try #require(rig.state().nextAttempt).timeIntervalSince(rig.clock.now))
        }
        #expect(waits == [3600, 7200, 14400])
    }

    @Test func aRefusedTokenIsNotRetried() async throws {
        let rig = try SyncRig(source: oneVault())
        rig.source.fail(with: OnePasswordError(kind: .authentication, message: "refused"))
        await rig.service.start()
        let summary = await rig.service.checkNow()
        #expect(summary.outcome == .tokenRefused)
        #expect(rig.state().nextAttempt == nil)
        rig.source.resetCalls()
        rig.service.noteRequest()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.source.calls.total == 0)
    }

    @Test func aRequestOnAStaleMacStartsACheck() async throws {
        let rig = try SyncRig(source: oneVault(sshItem("i1", title: "deploy")))
        await rig.service.start()
        rig.service.noteRequest()
        #expect(await eventually { (try? rig.store.list().count) == 1 })
        // A fresh success starts no second check.
        rig.source.resetCalls()
        rig.service.noteRequest()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.source.calls.total == 0)
        // Past the interval, the next request starts one.
        rig.clock.advance(301)
        rig.service.noteRequest()
        #expect(await eventually { rig.source.calls.vaults == 1 })
    }

    @Test func aRequestDuringBackoffStartsNoCheck() async throws {
        let rig = try SyncRig(source: oneVault(), random: 1)
        rig.source.fail(with: OnePasswordError(kind: .other, message: "offline"))
        await rig.service.start()
        _ = await rig.service.checkNow()
        rig.source.resetCalls()
        rig.clock.advance(301)
        rig.service.noteRequest()
        #expect(await eventually { rig.source.calls.vaults == 1 })
        rig.source.resetCalls()
        rig.service.noteRequest()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.source.calls.total == 0)
    }
}

@Suite struct StoredFormat {
    /// The item format before synced keys, which the Macs already hold.
    struct LegacyKey: Codable {
        var format = 1
        var name: String
        var kind: KeyKind
        var publicBlob: Data
        var comment: String
        var hosts: [String]
        var source: String
        var created: Date
        var keyData: Data
        var wrapped: WrappedKey?
    }

    @Test func anItemWrittenBeforeSyncedKeysDecodesWithNilFields() throws {
        let legacy = LegacyKey(name: "old", kind: .wrapped, publicBlob: Data([1]), comment: "", hosts: ["a"], source: "import", created: at(0), keyData: Data([2]))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let key = try PropertyListDecoder().decode(StoredKey.self, from: try encoder.encode(legacy))
        #expect(key.format == 1)
        #expect(key.name == "old")
        #expect(key.vaultID == nil)
        #expect(key.itemID == nil)
        #expect(key.itemUpdated == nil)
        #expect(!key.isSynced)
    }

    @Test func syncedFieldsSurviveAnEncodeAndDecode() throws {
        var key = storedSoftwareKey("synced")
        key.source = StoredKey.syncedSource
        key.vaultID = "v"
        key.itemID = "i"
        key.itemUpdated = at(5)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        #expect(try PropertyListDecoder().decode(StoredKey.self, from: try encoder.encode(key)) == key)
    }
}

/// The p99 of `samples`.
func p99(_ samples: [Duration]) -> Duration {
    let sorted = samples.sorted()
    return sorted[min(sorted.count - 1, sorted.count * 99 / 100)]
}

/// Runs list and sign requests against `server` for `seconds`, and returns how long each took.
func measure(_ server: Server, key: StoredKey, seconds: Double) async -> [Duration] {
    var samples: [Duration] = []
    let clock = ContinuousClock()
    let end = clock.now + .seconds(seconds)
    var count = 0
    while clock.now < end {
        let start = clock.now
        if count.isMultiple(of: 2) {
            _ = await server.respond(to: .identities)
        } else {
            _ = await server.respond(to: .sign(keyBlob: key.publicBlob, data: Data([1, 2, 3]), flags: []))
        }
        samples.append(clock.now - start)
        count += 1
        if count.isMultiple(of: 50) { await Task.yield() }
    }
    return samples
}

@Suite struct RequestsNeverWait {
    @Test func listAndSignKeepTheirP99WhileTheClientStartsAndACheckRuns() async throws {
        let key = storedSoftwareKey("served")
        let store = MemoryStore()
        try store.add(key)
        let agent = await makeAgent(store)
        let baseline = p99(await measure(Server(agent: agent), key: key, seconds: 1))

        let source = oneVault(sshItem("i1", title: "deploy"))
        source.slow(.seconds(2))
        let opened = Counter()
        let rig = try SyncRig(source: source, factory: { _ throws(OnePasswordError) in
            try? await Task.sleep(for: .seconds(2))
            opened.increment()
            return source
        })
        let server = Server(agent: agent, sync: rig.service)
        await rig.service.start()

        // The client takes two seconds to open, and the first request starts a check that waits for it.
        let whileStarting = await measure(server, key: key, seconds: 1)
        #expect(opened.value == 0)
        #expect(await eventually(4) { opened.value == 1 })
        // Each call to 1Password now takes two seconds.
        let whileChecking = await measure(server, key: key, seconds: 1)
        #expect(rig.source.calls.vaults == 1)
        #expect(rig.source.calls.items == 0)

        let limit = baseline * 3 + .milliseconds(5)
        #expect(p99(whileStarting) <= limit)
        #expect(p99(whileChecking) <= limit)
    }
}
