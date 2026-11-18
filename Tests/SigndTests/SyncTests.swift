import AgentProtocol
@testable import AgentServer
import CryptoKit
import Foundation
@testable import KeyStore
import SSHWire
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

/// Two devices on one account, the first holding a local key `deploy` with a host.
func twoDevices() throws -> (cloud: FakeCloud, a: DeviceRig, b: DeviceRig, key: PrivateKey) {
    let cloud = FakeCloud()
    let a = DeviceRig(cloud: cloud, name: "mac-a")
    let b = DeviceRig(cloud: cloud, name: "mac-b")
    let (stored, privateKey) = try localWrappedKey("deploy", hosts: ["git.example.com"], comment: "deploy key")
    try a.store.add(stored)
    return (cloud, a, b, privateKey)
}

// MARK: Records

@Test func payloadsKeepEveryFieldThroughAnEncodeAndDecode() throws {
    let wrapped = WrappedKey(encapsulatedKey: Data([1, 2]), ciphertext: Data([3, 4]))
    let key = KeyPayload(name: "deploy", comment: "c", hosts: ["h"], publicKey: Data([5]), sealed: ["device-1": wrapped])
    #expect(try Payload.decode(KeyPayload.self, from: Payload.encode(key)) == key)
    let device = DevicePayload(name: "mac-a", publicKey: Data([6]), version: "1.0.0")
    #expect(try Payload.decode(DevicePayload.self, from: Payload.encode(device)) == device)
}

@Test func aPayloadOfAnotherFormatIsReportedAndNotRead() {
    #expect(throws: PayloadError.format(2)) { try Payload.decode(KeyPayload.self, from: Data(#"{"format":2,"name":"x"}"#.utf8)) }
    #expect(throws: PayloadError.unreadable) { try Payload.decode(KeyPayload.self, from: Data("not json".utf8)) }
}

@Test func aDeviceRecordNameComesFromItsPublicKey() {
    let key = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    let name = DeviceKey.recordName(for: key)
    #expect(name.hasPrefix("device-"))
    #expect(name.count == "device-".count + 32)
    #expect(name == DeviceKey.recordName(for: key))
}

// MARK: Sharing

@Test(.timeLimit(.minutes(1))) func aSharedKeyReachesTheOtherDevice() async throws {
    let (cloud, a, b, privateKey) = try twoDevices()
    #expect(await b.service.checkNow().outcome == .ok)
    #expect(await a.service.share("deploy") == SyncResult(.done))

    let own = try #require(try a.store.list().first)
    #expect(own.isShared)
    #expect(own.recordName == "key-deploy")
    #expect(own.keyData == a.device.handle)
    let record = try #require(cloud.record("key-deploy"))
    let payload = try Payload.decode(KeyPayload.self, from: record.payload)
    #expect(Set(payload.sealed.keys) == [a.device.recordName, b.device.recordName])

    let summary = await b.service.checkNow()
    #expect(summary.added == ["deploy"])
    let received = try #require(try b.shared().first)
    #expect(received.hosts == ["git.example.com"])
    #expect(received.comment == "deploy key")
    #expect(received.isReceived)
    #expect(!own.isReceived)
    #expect(try softwareOpen(received).0.publicKey.blob == privateKey.publicKey.blob)
    #expect(b.changes.value == 1)
}

@Test(.timeLimit(.minutes(1))) func aDeviceThatJoinsLaterWaitsThenGetsTheKeyFromOneThatHasIt() async throws {
    let (_, a, b, privateKey) = try twoDevices()
    #expect(await a.service.share("deploy") == SyncResult(.done))

    _ = await b.service.checkNow()
    #expect(try b.shared().isEmpty)
    #expect(await b.service.snapshot().skipped.map(\.kind) == [.waiting])

    #expect(await a.service.checkNow().sealed == ["deploy"])
    #expect(await b.service.checkNow().added == ["deploy"])
    #expect(await b.service.snapshot().skipped.isEmpty)
    #expect(try softwareOpen(try #require(try b.shared().first)).0.publicKey.blob == privateKey.publicKey.blob)
}

@Test(.timeLimit(.minutes(1))) func deletingASharedKeyRemovesItOnEveryDevice() async throws {
    let (_, a, b, _) = try twoDevices()
    _ = await b.service.checkNow()
    _ = await a.service.share("deploy")
    _ = await b.service.checkNow()
    #expect(try b.shared().count == 1)

    #expect(await a.service.deleteShared("deploy") == SyncResult(.done))
    #expect(try a.store.list().isEmpty)
    #expect(await b.service.checkNow().removed == ["deploy"])
    #expect(try b.store.list().isEmpty)
}

@Test(.timeLimit(.minutes(1))) func aLocalKeyWithTheNameIsKeptAndTheSharedOneTakesItsPlaceOnceItIsDeleted() async throws {
    let (_, a, b, privateKey) = try twoDevices()
    let (other, _) = try localWrappedKey("deploy")
    try b.store.add(other)
    _ = await b.service.checkNow()
    _ = await a.service.share("deploy")

    _ = await b.service.checkNow()
    #expect(try b.store.list() == [other])
    #expect(await b.service.snapshot().skipped.map(\.kind) == [.nameTaken])
    // The record is known, so sharing this device's own key of that name is refused.
    #expect(await b.service.share("deploy").outcome == .failed)

    try b.store.delete(name: "deploy")
    #expect(await b.service.checkNow().added == ["deploy"])
    #expect(try softwareOpen(try #require(try b.shared().first)).0.publicKey.blob == privateKey.publicKey.blob)
}

@Test(.timeLimit(.minutes(1))) func aSecureEnclaveKeyIsNeverShared() async throws {
    let rig = DeviceRig(cloud: FakeCloud())
    try rig.store.add(storedSoftwareKey("build"))
    let result = await rig.service.share("build")
    #expect(result.outcome == .failed)
    #expect(result.message?.contains("cannot leave") == true)
    #expect(try rig.store.list().first?.isShared == false)
}

@Test(.timeLimit(.minutes(1))) func aNameAnotherDeviceSharedFirstIsRefused() async throws {
    let (cloud, a, _, _) = try twoDevices()
    _ = await a.service.share("deploy")
    let c = DeviceRig(cloud: cloud, name: "mac-c")
    let (own, _) = try localWrappedKey("deploy")
    try c.store.add(own)
    let result = await c.service.share("deploy")
    #expect(result.outcome == .failed)
    #expect(result.message?.contains("exists") == true)
}

@Test(.timeLimit(.minutes(1))) func removingADeviceDropsItsCopies() async throws {
    let (cloud, a, b, _) = try twoDevices()
    _ = await b.service.checkNow()
    _ = await a.service.share("deploy")
    #expect(await a.service.devices().count == 2)

    #expect(await a.service.removeDevice(b.device.recordName) == SyncResult(.done))
    let payload = try Payload.decode(KeyPayload.self, from: try #require(cloud.record("key-deploy")).payload)
    #expect(Array(payload.sealed.keys) == [a.device.recordName])
    #expect(cloud.record(b.device.recordName) == nil)
    #expect(await a.service.devices().map(\.isThisDevice) == [true])
    #expect(await a.service.removeDevice(a.device.recordName).outcome == .failed)
}

@Test(.timeLimit(.minutes(1))) func aCopyAnotherDeviceSealsDuringARemovalIsDroppedToo() async throws {
    let (cloud, a, b, privateKey) = try twoDevices()
    _ = await b.service.checkNow()
    _ = await a.service.share("deploy")
    // Another device's check, started before the Device record went, seals the key to b again.
    let resealed = try Wrapping.seal(privateKey, comment: "", to: b.agreement.publicKey)
    cloud.beforeNextDelete {
        guard let record = cloud.record("key-deploy"), var payload = try? Payload.decode(KeyPayload.self, from: record.payload) else { return }
        payload.sealed[b.device.recordName] = resealed
        cloud.put(.key, "key-deploy", payload: Payload.encode(payload))
    }
    #expect(await a.service.removeDevice(b.device.recordName) == SyncResult(.done))
    let payload = try Payload.decode(KeyPayload.self, from: try #require(cloud.record("key-deploy")).payload)
    #expect(Array(payload.sealed.keys) == [a.device.recordName])
}

@Test(.timeLimit(.minutes(1))) func aKeyThisMacMadeStaysItsOwnAfterAnotherDeviceSealsItAndTheZoneGoes() async throws {
    let (cloud, a, b, privateKey) = try twoDevices()
    _ = await a.service.share("deploy")
    _ = await b.service.checkNow()
    #expect(await a.service.checkNow().sealed == ["deploy"])
    // a reads back its own write, a changed record for a key it made.
    _ = await a.service.checkNow()
    #expect(try a.store.list().first?.isReceived == false)

    cloud.deleteZoneByUser()
    _ = await a.service.checkNow()
    let own = try #require(try a.store.list().first)
    #expect(!own.isShared)
    #expect(try softwareOpen(own).0.publicKey.blob == privateKey.publicKey.blob)
}

@Test(.timeLimit(.minutes(1))) func aZoneThatIsMissingKeepsThisMacsOwnKeys() async throws {
    let (cloud, a, b, privateKey) = try twoDevices()
    _ = await b.service.checkNow()
    _ = await a.service.share("deploy")
    _ = await b.service.checkNow()
    cloud.removeZone()
    #expect(await a.service.checkNow().outcome == .ok)
    #expect(try a.store.list().map(\.isShared) == [false])
    #expect(try softwareOpen(try #require(try a.store.list().first)).0.publicKey.blob == privateKey.publicKey.blob)
    #expect(await b.service.checkNow().outcome == .ok)
    #expect(try b.store.list().isEmpty)
}

@Test(.timeLimit(.minutes(1))) func aRemovalThatFailsKeepsTheDeviceRecordAndFinishesWhenRunAgain() async throws {
    let (cloud, a, b, _) = try twoDevices()
    _ = await b.service.checkNow()
    _ = await a.service.share("deploy")
    cloud.failSaves(with: CloudError(.network, "offline"))
    #expect(await a.service.removeDevice(b.device.recordName).outcome == .failed)
    #expect(cloud.record(b.device.recordName) != nil)

    cloud.failSaves(with: nil)
    #expect(await a.service.removeDevice(b.device.recordName) == SyncResult(.done))
    let payload = try Payload.decode(KeyPayload.self, from: try #require(cloud.record("key-deploy")).payload)
    #expect(Array(payload.sealed.keys) == [a.device.recordName])
    #expect(cloud.record(b.device.recordName) == nil)
}

// MARK: The check

@Test(.timeLimit(.minutes(1))) func anUnchangedZoneCostsOneRequest() async throws {
    let rig = DeviceRig(cloud: FakeCloud())
    #expect(await rig.service.checkNow().outcome == .ok)
    // The first check saved this device's record, which the second reads back.
    #expect(await rig.service.checkNow().requests == 2)
    let summary = await rig.service.checkNow()
    #expect(summary.outcome == .ok)
    #expect(summary.requests == 1)
}

@Test(.timeLimit(.minutes(1))) func anExpiredTokenFetchesEverythingAgain() async throws {
    let (cloud, a, b, _) = try twoDevices()
    _ = await b.service.checkNow()
    _ = await a.service.share("deploy")
    _ = await b.service.checkNow()
    cloud.expireNextToken()
    let summary = await b.service.checkNow()
    #expect(summary.outcome == .ok)
    #expect(try b.shared().count == 1)
    #expect(summary.removed.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func aRecordWithABadHostIsSkippedAndNamed() async throws {
    let cloud = FakeCloud()
    let rig = DeviceRig(cloud: cloud)
    _ = await rig.service.checkNow()
    let privateKey = memoryKey()
    let sealed = try Wrapping.seal(privateKey, comment: "", to: rig.agreement.publicKey)
    let payload = KeyPayload(name: "bad", comment: "", hosts: ["example.com ProxyCommand x"], publicKey: privateKey.publicKey.blob, sealed: [rig.device.recordName: sealed])
    cloud.put(.key, "key-bad", payload: Payload.encode(payload))
    _ = await rig.service.checkNow()
    #expect(try rig.store.list().isEmpty)
    let skipped = try #require(await rig.service.snapshot().skipped.first)
    #expect(skipped.kind == .invalidHost)
    #expect(skipped.reason.contains("ProxyCommand"))
}

@Test(.timeLimit(.minutes(1))) func aZoneDeletedInSettingsRemovesReceivedKeysKeepsOwnKeysAndWaitsForSync() async throws {
    let (cloud, a, b, privateKey) = try twoDevices()
    let (local, _) = try localWrappedKey("mine")
    try b.store.add(local)
    _ = await b.service.checkNow()
    _ = await a.service.share("deploy")
    _ = await b.service.checkNow()
    #expect(try b.shared().count == 1)

    cloud.deleteZoneByUser()
    #expect(await b.service.checkNow().outcome == .stopped)
    #expect(try b.store.list().map(\.name) == ["mine"])
    // The Mac that made the key keeps it, as its own key.
    #expect(await a.service.checkNow().outcome == .stopped)
    let own = try #require(try a.store.list().first)
    #expect(own.name == "deploy")
    #expect(!own.isShared)
    #expect(try softwareOpen(own).0.publicKey.blob == privateKey.publicKey.blob)
    let calls = cloud.calls.changes
    #expect(await b.service.checkNow().outcome == .stopped)
    #expect(cloud.calls.changes == calls)

    #expect(await b.service.syncRequested().outcome == .ok)
    #expect(await b.service.snapshot().stopped == false)
}

@Test(.timeLimit(.minutes(1))) func anotherAccountRemovesTheSharedKeys() async throws {
    let (cloud, a, b, _) = try twoDevices()
    _ = await b.service.checkNow()
    _ = await a.service.share("deploy")
    _ = await b.service.checkNow()
    #expect(try b.shared().count == 1)

    cloud.setAccount(.available(user: "user-2"))
    b.service.accountChanged()
    #expect(await eventually { (try? b.shared().isEmpty) == true })
    #expect(await b.service.snapshot().user == "user-2")
}

@Test(.timeLimit(.minutes(1))) func withNoAccountNothingIsSharedAndTheAccountIsAskedAgainInAMinute() async throws {
    let cloud = FakeCloud()
    cloud.setAccount(.unavailable("no iCloud account is signed in"))
    let rig = DeviceRig(cloud: cloud)
    let (key, _) = try localWrappedKey("k")
    try rig.store.add(key)
    #expect(await rig.service.share("k").outcome == .off)
    let state = await rig.service.snapshot()
    #expect(state.lastResult == .accountUnavailable)
    #expect(state.lastMessage == "no iCloud account is signed in")
    #expect(rig.clock.requestedSleeps.last == SyncSchedule.accountRecheck)
    #expect(try rig.store.list().first?.isShared == false)
}

@Test(.timeLimit(.minutes(1))) func withoutTheEntitlementSyncIsOffAndKeysStayLocal() async throws {
    let rig = DeviceRig(cloud: nil)
    await rig.service.start()
    #expect(await rig.service.snapshot().lastResult == .off)
    #expect(SyncState.load(from: rig.stateURL).lastResult == .off)
    #expect(await rig.service.share("k").outcome == .off)
    #expect(await rig.service.syncRequested().outcome == .off)
}

@Test(.timeLimit(.minutes(1))) func theStateFileHoldsNoPrivateKeyOrSealedCopy() async throws {
    let (cloud, a, _, privateKey) = try twoDevices()
    _ = await a.service.share("deploy")
    let text = try String(contentsOf: a.stateURL, encoding: .utf8)
    let payload = try Payload.decode(KeyPayload.self, from: try #require(cloud.record("key-deploy")).payload)
    for copy in payload.sealed.values { #expect(!text.contains(copy.ciphertext.base64EncodedString())) }
    var secret = Data()
    privateKey.write(to: &secret)
    #expect(!text.contains(secret.base64EncodedString()))
}

// MARK: The schedule

@Test func eachWaitAfterASuccessIsTheIntervalTimesZeroPointEightToOnePointTwo() {
    #expect(SyncSchedule(random: { 0 }).afterSuccess(interval: 2) == 1.6)
    #expect(SyncSchedule(random: { 0.5 }).afterSuccess(interval: 2) == 2)
    #expect(SyncSchedule(random: { 0.999 }).afterSuccess(interval: 2) < 2.4)
}

@Test func failuresDoubleTheWaitUpToAMinute() {
    let schedule = SyncSchedule(random: { 0.999_999 })
    #expect(abs(schedule.afterFailure(interval: 2, failures: 1) - 2) < 0.001)
    #expect(abs(schedule.afterFailure(interval: 2, failures: 3) - 8) < 0.001)
    #expect(abs(schedule.afterFailure(interval: 2, failures: 20) - 60) < 0.001)
    #expect(SyncSchedule(random: { 0 }).afterFailure(interval: 2, failures: 1) == 1)
}

@Test func aThrottleWaitsTheRetryAfterTimeAndAtLeastTheInterval() {
    let schedule = SyncSchedule(random: { 0.5 })
    #expect(schedule.afterThrottle(interval: 2, retryAfter: 30, failures: 1) == 30)
    #expect(schedule.afterThrottle(interval: 2, retryAfter: 0.5, failures: 1) == 2)
    #expect(schedule.afterThrottle(interval: 2, retryAfter: nil, failures: 3) == 6)
}

@Test(.timeLimit(.minutes(1))) func theServiceWaitsTheIntervalAfterASuccessAndTheRetryAfterTimeAfterAThrottle() async throws {
    let cloud = FakeCloud()
    let rig = DeviceRig(cloud: cloud)
    _ = await rig.service.checkNow()
    #expect(rig.clock.requestedSleeps.last == 2)

    cloud.fail(with: CloudError(.throttled, "throttled", retryAfter: 30))
    #expect(await rig.service.checkNow().outcome == .throttled)
    #expect(rig.clock.requestedSleeps.last == 30)
    let state = await rig.service.snapshot()
    #expect(state.nextAttempt == state.lastCheck?.addingTimeInterval(30))

    cloud.fail(with: CloudError(.network, "offline"))
    #expect(await rig.service.checkNow().outcome == .failed)
    #expect(rig.clock.requestedSleeps.last == 3)
}

@Test(.timeLimit(.minutes(1))) func aPushStartsACheckUnlessTheServiceIsBackingOff() async throws {
    let cloud = FakeCloud()
    let rig = DeviceRig(cloud: cloud)
    _ = await rig.service.checkNow()
    rig.service.pushArrived()
    #expect(await eventually { cloud.calls.changes == 2 })
    #expect(await rig.service.snapshot().lastPush != nil)
    // Joins the check the push started, so the failure below lands on a check of its own.
    _ = await rig.service.checkNow()

    cloud.fail(with: CloudError(.network, "offline"))
    _ = await rig.service.checkNow()
    let calls = cloud.calls.changes
    let failures = await rig.service.snapshot().failures
    rig.service.pushArrived()
    try await Task.sleep(for: .milliseconds(200))
    #expect(cloud.calls.changes == calls, "calls \(calls) then \(cloud.calls.changes), failures \(failures), sleeps \(rig.clock.requestedSleeps)")
}

@Test(.timeLimit(.minutes(1))) func listAndSignKeepTheirP99WhileACheckWaitsOnASlowCloud() async throws {
    let key = storedSoftwareKey("served")
    let store = MemoryStore()
    try store.add(key)
    let agent = await makeAgent(store)
    let baseline = p99(await measure(Server(agent: agent), key: key, seconds: 1))

    let cloud = FakeCloud()
    cloud.slow(.seconds(2))
    let rig = DeviceRig(cloud: cloud)
    let server = Server(agent: agent, sync: rig.service)
    await rig.service.start()
    #expect(await eventually(2) { cloud.calls.account == 1 })
    let whileChecking = await measure(server, key: key, seconds: 1)
    #expect(p99(whileChecking) <= baseline * 3 + .milliseconds(5))
}

// MARK: Settings and status

@Test(arguments: ["infs", "nans", "1e25s", "0s", "3601s", "2h", "-1m", "5"])
func anIntervalOutsideItsBoundsIsRefused(text: String) {
    #expect(Settings.validSeconds(.interval, text) == nil)
}

@Test(arguments: ["infs", "1e25s", "0s", "31d", "-1s"])
func aKeyLifetimeOutsideItsBoundsIsRefused(text: String) {
    #expect(Settings.validSeconds(.keyLifetime, text) == nil)
}

@Test func durationsAtTheBoundsAreAccepted() {
    #expect(Settings.validSeconds(.interval, "1s") == 1)
    #expect(Settings.validSeconds(.interval, "1h") == 3600)
    #expect(Settings.validSeconds(.keyLifetime, "1s") == 1)
    #expect(Settings.validSeconds(.keyLifetime, "30d") == 2_592_000)
}

@Test func theDefaultIntervalIsTwoSeconds() {
    let resolved = Settings(local: { _ in nil }).resolve(.interval)
    #expect(resolved.seconds == 2)
    #expect(resolved.source == .default)
}

@Test func aBadSettingIsRefusedBeforeItIsWritten() {
    #expect(throws: SettingsError.self) { try Settings().set(.interval, "infs") }
    #expect(throws: SettingsError.self) { try Settings().set(.keyLifetime, "1e25s") }
}

@Test func aLocalSettingOutOfBoundsIsShownAsIgnoredWithItsReason() throws {
    let settings = Settings(local: { $0 == .interval ? "2h" : nil })
    let status = SyncStatus(state: SyncState(), settings: settings)
    #expect(status.interval.source == .default)
    #expect(status.interval.seconds == 2)
    #expect(status.ignoredSettings.map(\.key) == ["interval"])
    #expect(status.ignoredSettings.first?.reason == "not a duration such as 90s, 30m, 1h or 2d from 1 to 3600 seconds")
}

@Test(.timeLimit(.minutes(1))) func statusJSONCarriesTheStateTheLastResultTheNextCheckAndEverySkippedKey() async throws {
    let (_, a, b, _) = try twoDevices()
    _ = await a.service.share("deploy")
    _ = await b.service.checkNow()
    let status = SyncStatus(state: await b.service.snapshot(), settings: Settings(local: { _ in nil }))
    let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
    #expect(json["state"] as? String == "on")
    #expect(json["lastResult"] as? String == "ok")
    #expect(json["nextAttempt"] != nil)
    #expect(json["devices"] as? Int == 2)
    #expect((json["skipped"] as? [[String: Any]])?.first?["kind"] as? String == "waiting")
}

// MARK: Stored keys

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
    var vaultID: String?
    var itemID: String?
}

@Test func anItemAnOlderReleaseWroteStillDecodes() throws {
    let legacy = LegacyKey(
        name: "old", kind: .wrapped, publicBlob: Data([1]), comment: "", hosts: ["a"], source: "1password", created: at(0), keyData: Data([2]),
        vaultID: "v", itemID: "i"
    )
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let key = try PropertyListDecoder().decode(StoredKey.self, from: try encoder.encode(legacy))
    #expect(key.name == "old")
    #expect(key.recordName == nil)
    #expect(!key.isShared)
}

@Test func aSharedKeySurvivesAnEncodeAndDecode() throws {
    var key = try localWrappedKey("k").0
    key.recordName = "key-k"
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    #expect(try PropertyListDecoder().decode(StoredKey.self, from: try encoder.encode(key)) == key)
}

// MARK: Private extensions

@Test func aForwardedConnectionMayUseNoPrivateExtension() async throws {
    let store = MemoryStore()
    let agent = await makeAgent(store)
    let server = Server(agent: agent)
    let connection = Connection(peerPID: getpid())
    let status = Request.extension(name: PrivateExtension.status, contents: Data())
    guard case .extensionResponse = await server.respond(to: status, on: connection) else {
        Issue.record("status was refused on a connection that is not forwarded")
        return
    }
    var bind = Data()
    bind.appendString(Data([1]))
    bind.appendString(Data([2]))
    bind.appendString(Data([3]))
    bind.append(1)
    #expect(await server.respond(to: .extension(name: Extension.sessionBind, contents: bind), on: connection) == .success)
    #expect(await server.respond(to: status, on: connection) == .failure)
    #expect(await server.respond(to: .extension(name: PrivateExtension.sync, contents: Data()), on: connection) == .failure)
    var share = Data()
    share.appendString(Data("k".utf8))
    #expect(await server.respond(to: .extension(name: PrivateExtension.share, contents: share), on: connection) == .failure)
    // A bind that says it is not forwarded leaves a connection as it was.
    let local = Connection(peerPID: getpid())
    bind.removeLast()
    bind.append(0)
    _ = await server.respond(to: .extension(name: Extension.sessionBind, contents: bind), on: local)
    guard case .extensionResponse = await server.respond(to: status, on: local) else {
        Issue.record("status was refused on a connection that is not forwarded")
        return
    }
}

@Test func privateExtensionsNeedAPeerThatRunsTheAgentsOwnExecutable() async throws {
    let server = Server(agent: await makeAgent(MemoryStore()))
    let status = Request.extension(name: PrivateExtension.status, contents: Data())
    guard case .extensionResponse = await server.respond(to: status, on: Connection(peerPID: getpid())) else {
        Issue.record("status was refused to a process that runs this executable")
        return
    }
    #expect(await server.respond(to: status, on: Connection(peerPID: nil)) == .failure)
    #expect(await server.respond(to: status, on: Connection(peerPID: 1)) == .failure)
    #expect(await server.respond(to: .extension(name: PrivateExtension.reload, contents: Data()), on: Connection(peerPID: 1)) == .failure)
    // The other requests stay open to every process of the user.
    #expect(await server.respond(to: .extension(name: Extension.query, contents: Data()), on: Connection(peerPID: nil)) == .query)
    #expect(FileIdentity(executableOf: getpid()) != nil)
    #expect(FileIdentity(executableOf: getpid()) == FileIdentity(executableOf: getpid()))
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

