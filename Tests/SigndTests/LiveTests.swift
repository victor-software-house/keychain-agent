import Foundation
import KeyStore
import OnePassword
import SSHWire
import Testing
@testable import Sync

let liveToken = ProcessInfo.processInfo.environment["OP_TEST_SERVICE_ACCOUNT_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }

/// Runs the check against a test vault with one SSH Key item, `test-key`, through the real 1Password client; skipped without a token.
@Test(.enabled(if: liveToken != nil), .timeLimit(.minutes(1))) func syncsTheTestKey() async throws {
    let token = try #require(liveToken)
    let client = try await Client(token: token, integrationName: "signd-tests", integrationVersion: "0")
    let rig = try SyncRig(source: FakeSource(), factory: { _ in client })
    await rig.service.start()
    let summary = await rig.service.checkNow()
    #expect(summary.outcome == .ok, "\(summary.message ?? "no message")")

    let key = try #require(try rig.store.list().first)
    #expect(try rig.store.list().map(\.name) == ["test-key"])
    #expect(key.hosts == ["example.invalid"])
    #expect(key.source == "1password")

    #expect(key.publicKey?.keyType == "ssh-ed25519")

    // The item's own public key names the stored key.
    var compared = 0
    for vault in try await client.vaults() {
        for overview in try await client.items(vaultID: vault.id) where overview.title == "test-key" {
            let item = try await client.item(vaultID: vault.id, itemID: overview.id)
            let line = try #require(item.fields.first { $0.fieldType == "SshKey" }?.publicKey)
            let blob = try #require(line.split(separator: " ").dropFirst().first)
            #expect(key.publicBlob.base64EncodedString() == String(blob))
            compared += 1
        }
    }
    #expect(compared == 1)
}
