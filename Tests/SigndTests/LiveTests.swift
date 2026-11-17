import Foundation
import KeyStore
import OnePassword
import SSHWire
import Testing
@testable import Sync

let liveToken = ProcessInfo.processInfo.environment["OP_TEST_SERVICE_ACCOUNT_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }

/// Runs the check against a test vault with one SSH Key item, `test-key`, through the real 1Password client; skipped without a token.
@Suite(.enabled(if: liveToken != nil)) struct LiveOnePassword {
    @Test func syncsTheTestKey() async throws {
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

        // The binding gives no public key for an SSH Key item whose only fields are the private key and the hosts, as the test item is.
        // When the item does carry a public key field, it must name the same key.
        for vault in try await client.vaults() {
            for overview in try await client.items(vaultID: vault.id) where overview.title == "test-key" {
                let item = try await client.item(vaultID: vault.id, itemID: overview.id)
                let line = item.fields.first { $0.id == "public_key" || $0.title.lowercased() == "public key" }?.value
                if let blob = line?.split(separator: " ").dropFirst().first {
                    #expect(key.publicBlob.base64EncodedString() == String(blob))
                }
            }
        }
    }
}
