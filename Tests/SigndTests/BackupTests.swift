import ArgumentParser
import CryptoKit
import Foundation
@testable import KeyStore
import Testing
@testable import signd
@testable import Sync

private let token = Data("ops_example-service-account-token".utf8)

@Test func theBackupPayloadNeverContainsTheToken() throws {
    let agreement = P256.KeyAgreement.PrivateKey()
    let payload = BackupPayload(vault: "signd", sealed: ["device-1": try Wrapping.seal(secret: token, to: agreement.publicKey)])
    let json = Payload.encode(payload)
    let text = String(decoding: json, as: UTF8.self)
    #expect(json.range(of: token) == nil)
    #expect(!text.contains(String(decoding: token, as: UTF8.self)))
    #expect(!text.contains(token.base64EncodedString()))
    #expect(try Payload.decode(BackupPayload.self, from: json) == payload)
}

@Test func loginRefusesATokenAsAnArgumentAndCallsNoAgent() throws {
    let login = try BackupCommand.Login.parse(["ops_example-token"])
    let reads = Counter()
    let failure = #expect(throws: Failure.self) {
        try login.run(client: AgentClient(path: "/nonexistent/signd.sock"), settings: Settings(local: { _ in nil })) {
            reads.increment()
            return Data()
        }
    }
    // A call to the agent would fail with "the agent does not answer".
    #expect(failure?.description == "pass the token on stdin, never as an argument")
    #expect(reads.value == 0)
}

/// A device that has logged in to the backup, and one that has not seen it yet, on one account.
private func loggedInAndWaiting() async throws -> (cloud: FakeCloud, a: DeviceRig, b: DeviceRig) {
    let cloud = FakeCloud()
    let a = DeviceRig(cloud: cloud, name: "mac-a")
    let b = DeviceRig(cloud: cloud, name: "mac-b")
    _ = await b.service.checkNow()
    #expect(await a.service.backupLogin(token: token, vault: "signd") == SyncResult(.done))
    return (cloud, a, b)
}

@Test(.timeLimit(.minutes(1))) func aCheckStoresTheTokenFromTheBackupRecord() async throws {
    let (cloud, a, b) = try await loggedInAndWaiting()
    #expect(try a.tokens.read() == token)
    #expect(try b.tokens.read() == nil)
    let payload = try Payload.decode(BackupPayload.self, from: try #require(cloud.record(BackupPayload.recordName)).payload)
    #expect(payload.vault == "signd")
    #expect(Set(payload.sealed.keys) == [a.device.recordName, b.device.recordName])

    #expect(await b.service.checkNow().outcome == .ok)
    #expect(try b.tokens.read() == token)
}

@Test(.timeLimit(.minutes(1))) func aCompletedFullReadWithoutTheBackupRecordDeletesTheToken() async throws {
    let (cloud, _, b) = try await loggedInAndWaiting()
    _ = await b.service.checkNow()
    #expect(try b.tokens.read() == token)

    // The zone is gone with no deletion to read, so the next read is a full one and finds no Backup record.
    cloud.removeZone()
    #expect(await b.service.checkNow().outcome == .ok)
    #expect(try b.tokens.read() == nil)
}

@Test(.timeLimit(.minutes(1))) func aDeletedBackupRecordDeletesTheTokenOnEveryMac() async throws {
    let (_, a, b) = try await loggedInAndWaiting()
    _ = await b.service.checkNow()
    #expect(await a.service.backupLogout() == SyncResult(.done))
    #expect(try a.tokens.read() == nil)

    #expect(await b.service.checkNow().outcome == .ok)
    #expect(try b.tokens.read() == nil)
}

@Test(.timeLimit(.minutes(1))) func aBackupRecordThisVersionCannotReadKeepsTheToken() async throws {
    let (cloud, _, b) = try await loggedInAndWaiting()
    _ = await b.service.checkNow()
    cloud.put(.backup, BackupPayload.recordName, payload: Data(#"{"format":2}"#.utf8))

    #expect(await b.service.checkNow().outcome == .ok)
    #expect(try b.tokens.read() == token)
}

@Test(.timeLimit(.minutes(1))) func aNewDeviceGetsASealedCopyFromAMacThatHoldsTheToken() async throws {
    let cloud = FakeCloud()
    let a = DeviceRig(cloud: cloud, name: "mac-a")
    let b = DeviceRig(cloud: cloud, name: "mac-b")
    #expect(await a.service.backupLogin(token: token, vault: "signd") == SyncResult(.done))

    // The new device publishes its record, and has no copy yet.
    _ = await b.service.checkNow()
    #expect(try b.tokens.read() == nil)

    _ = await a.service.checkNow()
    let payload = try Payload.decode(BackupPayload.self, from: try #require(cloud.record(BackupPayload.recordName)).payload)
    #expect(Set(payload.sealed.keys) == [a.device.recordName, b.device.recordName])

    _ = await b.service.checkNow()
    #expect(try b.tokens.read() == token)
}

private let newerToken = Data("ops_second-service-account-token".utf8)

private func backupPayload(_ cloud: FakeCloud) throws -> BackupPayload {
    try Payload.decode(BackupPayload.self, from: try #require(cloud.record(BackupPayload.recordName)).payload)
}

@Test(.timeLimit(.minutes(1))) func aMacWithNoCopyInTheRecordDeletesItsOldTokenAndSealsNothingWithIt() async throws {
    let cloud = FakeCloud()
    let a = DeviceRig(cloud: cloud, name: "mac-a")
    let b = DeviceRig(cloud: cloud, name: "mac-b")
    let c = DeviceRig(cloud: cloud, name: "mac-c")
    for rig in [a, b, c] { _ = await rig.service.checkNow() }
    _ = await a.service.checkNow()
    #expect(await a.service.backupLogin(token: token, vault: "signd") == SyncResult(.done))
    for rig in [b, c] { _ = await rig.service.checkNow() }
    for rig in [a, b, c] { #expect(try rig.tokens.read() == token) }

    // Mac c is missing from mac a's list of devices when mac a logs in again, so the new record has no copy for it.
    try await cloud.delete(.device, name: c.device.recordName)
    _ = await a.service.checkNow()
    #expect(await a.service.backupLogin(token: newerToken, vault: "signd") == SyncResult(.done))

    #expect(await c.service.checkNow().outcome == .ok)
    #expect(try c.tokens.read() == nil)
    let payload = try backupPayload(cloud)
    #expect(Set(payload.sealed.keys) == [a.device.recordName, b.device.recordName])
    for rig in [a, b] {
        #expect(try Wrapping.open(try #require(payload.sealed[rig.device.recordName]), with: rig.agreement) == newerToken)
    }

    #expect(await a.service.checkNow().outcome == .ok)
    #expect(await c.service.checkNow().outcome == .ok)
    #expect(try c.tokens.read() == newerToken)
}

@Test(.timeLimit(.minutes(1))) func removingADeviceDropsItsCopyOfTheToken() async throws {
    let (cloud, a, b) = try await loggedInAndWaiting()
    #expect(await a.service.removeDevice(b.device.recordName) == SyncResult(.done))
    #expect(Array(try backupPayload(cloud).sealed.keys) == [a.device.recordName])
    #expect(await a.service.snapshot().backup?.sealedFor == [a.device.recordName])
}

@Test(.timeLimit(.minutes(1))) func removingADeviceReadsTheBackupRecordAgainWhenAnotherDeviceSavedItFirst() async throws {
    let (cloud, a, b) = try await loggedInAndWaiting()
    // Another device saves the record between the removal's read and its write.
    cloud.beforeNextSave {
        guard let record = cloud.record(BackupPayload.recordName) else { return }
        cloud.put(.backup, BackupPayload.recordName, payload: record.payload)
    }
    #expect(await a.service.removeDevice(b.device.recordName) == SyncResult(.done))
    #expect(Array(try backupPayload(cloud).sealed.keys) == [a.device.recordName])
    #expect(await a.service.snapshot().backup?.sealedFor == [a.device.recordName])
}

@Test(.timeLimit(.minutes(1))) func aFullReadThatCannotReadTheBackupRecordKeepsTheToken() async throws {
    let (cloud, _, b) = try await loggedInAndWaiting()
    _ = await b.service.checkNow()
    #expect(try b.tokens.read() == token)

    // The change token expires, so the next read is a full one, and CloudKit fails the Backup record in it.
    cloud.failReads(of: [BackupPayload.recordName])
    cloud.expireNextToken()
    #expect(await b.service.checkNow().outcome == .failed)
    #expect(try b.tokens.read() == token)

    cloud.failReads(of: [])
    #expect(await b.service.checkNow().outcome == .ok)
    #expect(try b.tokens.read() == token)
}

@Test(.timeLimit(.minutes(1))) func aZoneDeletedByTheUserDeletesTheToken() async throws {
    let (cloud, _, b) = try await loggedInAndWaiting()
    _ = await b.service.checkNow()
    #expect(try b.tokens.read() == token)

    cloud.deleteZoneByUser()
    #expect(await b.service.checkNow().outcome == .stopped)
    #expect(try b.tokens.read() == nil)
}

@Test(.timeLimit(.minutes(1))) func anotherAccountDeletesTheToken() async throws {
    let (cloud, _, b) = try await loggedInAndWaiting()
    _ = await b.service.checkNow()
    #expect(try b.tokens.read() == token)

    // The check that follows fails, so only the change of account can have deleted the token.
    cloud.failChanges(with: CloudError(.network, "offline"))
    cloud.setAccount(.available(user: "user-2"))
    b.service.accountChanged()
    #expect(await eventually { (try? b.tokens.read()) == nil })
}

@Test(.timeLimit(.minutes(1))) func theStateFileAndTheResultsNeverContainTheToken() async throws {
    let cloud = FakeCloud()
    let a = DeviceRig(cloud: cloud, name: "mac-a")
    let b = DeviceRig(cloud: cloud, name: "mac-b")
    _ = await b.service.checkNow()
    let login = await a.service.backupLogin(token: token, vault: "signd")
    let checks = [await a.service.checkNow(), await b.service.checkNow()]
    #expect(login == SyncResult(.done))
    #expect(try b.tokens.read() == token)

    let text = String(decoding: token, as: UTF8.self)
    let encoded = token.base64EncodedString()
    for rig in [a, b] {
        let file = try Data(contentsOf: rig.stateURL)
        let json = String(decoding: file, as: UTF8.self)
        #expect(file.range(of: token) == nil)
        #expect(!json.contains(text))
        #expect(!json.contains(encoded))
    }
    for message in [login.message] + checks.map(\.message) {
        #expect(!(message ?? "").contains(text))
        #expect(!(message ?? "").contains(encoded))
    }
}
