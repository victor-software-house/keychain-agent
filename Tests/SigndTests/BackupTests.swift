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
