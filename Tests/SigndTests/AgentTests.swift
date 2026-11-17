import AgentProtocol
@testable import AgentServer
import CryptoKit
import Foundation
import KeyStore
import Synchronization
import SSHWire
import Testing

/// A store in memory, for tests on runners without a Secure Enclave or signd's entitlements.
final class MemoryStore: KeyStore {
    private let keys = Mutex<[StoredKey]>([])

    func list() throws(StoreError) -> [StoredKey] { keys.withLock { $0 } }

    func add(_ key: StoredKey) throws(StoreError) {
        try keys.withLock { keys throws(StoreError) in
            if keys.contains(where: { $0.name == key.name }) { throw .duplicate(key.name) }
            keys.append(key)
        }
    }

    func delete(name: String) throws(StoreError) {
        try keys.withLock { keys throws(StoreError) in
            guard keys.contains(where: { $0.name == name }) else { throw .notFound(name) }
            keys.removeAll { $0.name == name }
        }
    }
}

/// A stored key whose `keyData` is an Ed25519 seed, opened by `softwareOpener` in place of the Secure Enclave.
func storedSoftwareKey(_ name: String) -> StoredKey {
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = PublicKey.ed25519(key.publicKey.rawRepresentation)
    return StoredKey(name: name, kind: .secureEnclave, publicBlob: publicKey.blob, comment: "", hosts: [], keyData: key.rawRepresentation)
}

let softwareOpener: Agent.Opener = { key throws(SignError) in
    guard case let .ed25519(publicKey)? = key.publicKey else { throw .invalidKey("test keys are Ed25519") }
    return try SoftwareSigner(.ed25519(seed: key.keyData, publicKey: publicKey))
}

func makeAgent(_ store: MemoryStore, lifetime: TimeInterval = 3600) async -> Agent {
    let agent = Agent(store: store, version: "test", lifetime: { lifetime }, opener: softwareOpener)
    await agent.reload()
    return agent
}

func memoryKey() -> PrivateKey {
    let key = Curve25519.Signing.PrivateKey()
    return .ed25519(seed: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation)
}

@Suite struct AgentState {
    @Test func listsStoredAndMemoryOnlyKeys() async throws {
        let store = MemoryStore()
        try store.add(storedSoftwareKey("stored"))
        let agent = await makeAgent(store)
        #expect(await agent.add(memoryKey(), comment: "added", constraints: Constraints()) == .success)
        #expect(await agent.identities().map(\.comment) == ["stored", "added"])
    }

    @Test func aLifetimeConstraintDropsTheKey() async {
        let agent = await makeAgent(MemoryStore())
        _ = await agent.add(memoryKey(), comment: "brief", constraints: Constraints(lifetime: 2))
        await agent.dropExpired(now: Date().addingTimeInterval(3))
        #expect(await agent.identities().isEmpty)
    }

    @Test func confirmAndExtensionConstraintsAreRefused() async {
        let agent = await makeAgent(MemoryStore())
        #expect(await agent.add(memoryKey(), comment: "", constraints: Constraints(confirm: true)) == .failure)
        #expect(await agent.add(memoryKey(), comment: "", constraints: Constraints(extensions: ["x@example.com"])) == .failure)
        #expect(await agent.identities().isEmpty)
    }

    @Test func removeAllKeepsStoredKeys() async throws {
        let store = MemoryStore()
        let stored = storedSoftwareKey("stored")
        try store.add(stored)
        let agent = await makeAgent(store)
        _ = await agent.add(memoryKey(), comment: "added", constraints: Constraints())
        #expect(await agent.removeAll() == .success)
        #expect(await agent.remove(blob: stored.publicBlob) == .failure)
        #expect(await agent.identities().map(\.comment) == ["stored"])
    }

    @Test func anOpenKeyLeavesMemoryAfterItsLifetime() async throws {
        let store = MemoryStore()
        let stored = storedSoftwareKey("stored")
        try store.add(stored)
        let agent = await makeAgent(store, lifetime: 1)
        #expect(await agent.signer(for: stored.publicBlob) != nil)
        #expect(await agent.status().keys.first?.inMemory == true)
        await agent.dropExpired(now: Date().addingTimeInterval(2))
        #expect(await agent.status().keys.first?.inMemory == false)
    }

    @Test func aKeyAddedToTheStoreIsFoundOnFirstSign() async throws {
        let store = MemoryStore()
        let agent = await makeAgent(store)
        let stored = storedSoftwareKey("later")
        try store.add(stored)
        #expect(await agent.signer(for: stored.publicBlob) != nil)
    }
}

/// Signs slowly, standing in for the Secure Enclave.
struct SlowSigner: Signer {
    let publicKey = PublicKey.ed25519(Data(repeating: 5, count: 32))
    func sign(_: Data, flags _: SignFlags) throws(SignError) -> Signature {
        usleep(5000)
        return Signature(algorithm: "ssh-ed25519", bytes: Data(repeating: 0, count: 64))
    }
}

@Suite struct Concurrency {
    @Test func slowSignaturesDoNotDelayAListRequest() async throws {
        let store = MemoryStore()
        let stored = storedSoftwareKey("slow")
        try store.add(stored)
        let agent = Agent(store: store, version: "test", lifetime: { 3600 }, opener: { _ throws(SignError) in SlowSigner() })
        await agent.reload()
        let server = Server(agent: agent)
        try await withThrowingTaskGroup { group in
            for _ in 0..<32 {
                group.addTask {
                    for _ in 0..<100 {
                        let response = await server.respond(to: .sign(keyBlob: stored.publicBlob, data: Data([1]), flags: []))
                        guard case .signature = response else { throw SignError.failed("no signature") }
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(50))
            let start = ContinuousClock.now
            _ = await server.respond(to: .identities)
            #expect(ContinuousClock.now - start < .milliseconds(10))
            try await group.waitForAll()
        }
    }
}
