import AgentProtocol
import Foundation
import KeyStore
import os
import SSHEncoding

let log = Logger(subsystem: "com.victor-software-house.signd", category: "agent")

/// The agent's state: stored keys, the private keys open in memory, and memory-only keys.
public actor Agent {
    private struct Open {
        let signer: any Signer
        var lastUsed: Date
    }

    private struct SessionKey {
        let signer: any Signer
        let comment: String
        let expires: Date?
    }

    private let store: any KeyStore
    let lifetime: @Sendable () -> TimeInterval
    private let version: String
    private var stored: [StoredKey] = []
    private var storeError: StoreError?
    private var open: [Data: Open] = [:]
    /// Stored keys whose last open failed; they are not listed until the next reload.
    private var failed: Set<Data> = []
    private var session: [(blob: Data, key: SessionKey)] = []
    private var sessionBinds = 0

    /// Opens a stored key for signing.
    public typealias Opener = @Sendable (StoredKey) throws(SignError) -> any Signer

    private let opener: Opener
    private let keysRead: @Sendable ([StoredKey]) -> Void

    /// `keysRead` runs after each successful read of the stored keys, as the SSH routing files follow them.
    public init(
        store: any KeyStore, version: String, lifetime: @escaping @Sendable () -> TimeInterval, opener: @escaping Opener = Agent.openStored,
        keysRead: @escaping @Sendable ([StoredKey]) -> Void = { _ in }
    ) {
        self.store = store
        self.version = version
        self.lifetime = lifetime
        self.opener = opener
        self.keysRead = keysRead
    }

    /// Opens a key by its type: a Secure Enclave key through its handle, a wrapped key by opening its seal into memory.
    public static let openStored: Opener = { key throws(SignError) in
        switch key.kind {
        case .secureEnclave: try SecureEnclaveSigner(handle: key.keyData)
        case .wrapped: try SoftwareSigner(opening: key)
        }
    }

    /// Reads the stored keys again, as after a command added or deleted one.
    public func reload() {
        do {
            stored = try store.list()
            storeError = nil
            failed = []
            let blobs = Set(stored.map(\.publicBlob))
            open = open.filter { blobs.contains($0.key) }
            keysRead(stored)
        } catch {
            stored = []
            open = [:]
            failed = []
            if storeError != error { log.error("cannot read stored keys: \(error.description, privacy: .public)") }
            storeError = error
        }
    }

    public func identities() -> [Identity] {
        if storeError != nil { reload() }
        dropExpired(now: Date())
        return listed.map { Identity(blob: $0.publicBlob, comment: $0.displayComment) }
            + session.map { Identity(blob: $0.blob, comment: $0.key.comment) }
    }

    private var listed: [StoredKey] { stored.filter { !failed.contains($0.publicBlob) } }

    /// The signer for a key blob, opening a stored key on first use.
    public func signer(for blob: Data) -> (any Signer)? {
        let now = Date()
        dropExpired(now: now)
        if let entry = session.first(where: { $0.blob == blob }) { return entry.key.signer }
        if var entry = open[blob] {
            entry.lastUsed = now
            open[blob] = entry
            return entry.signer
        }
        if !stored.contains(where: { $0.publicBlob == blob }) { reload() }
        guard let key = stored.first(where: { $0.publicBlob == blob }) else { return nil }
        do {
            let signer = try opener(key)
            open[blob] = Open(signer: signer, lastUsed: now)
            return signer
        } catch {
            log.error("cannot open key \(key.name, privacy: .public): \(String(describing: error), privacy: .public)")
            failed.insert(blob)
            return nil
        }
    }

    /// Adds a memory-only key, as ssh-add expects.
    public func add(_ privateKey: PrivateKey, comment: String, constraints: Constraints) -> Response {
        guard !constraints.confirm, constraints.extensions.isEmpty else { return .failure }
        let signer: any Signer
        do {
            signer = try SoftwareSigner(privateKey)
        } catch {
            log.notice("refused a key: \(String(describing: error), privacy: .public)")
            return .failure
        }
        let blob = signer.publicKey.blob
        let expires = constraints.lifetime.map { Date().addingTimeInterval(TimeInterval($0)) }
        session.removeAll { $0.blob == blob }
        session.append((blob, SessionKey(signer: signer, comment: comment, expires: expires)))
        return .success
    }

    /// Removes a memory-only key; stored keys stay.
    public func remove(blob: Data) -> Response {
        guard session.contains(where: { $0.blob == blob }) else { return .failure }
        session.removeAll { $0.blob == blob }
        return .success
    }

    public func removeAll() -> Response {
        session.removeAll()
        return .success
    }

    public func recordSessionBind() {
        sessionBinds += 1
    }

    /// Drops private keys unused for the key lifetime, and memory-only keys past their lifetime.
    public func dropExpired(now: Date) {
        let limit = lifetime()
        open = open.filter { now.timeIntervalSince($0.value.lastUsed) < limit }
        session.removeAll { $0.key.expires.map { $0 <= now } ?? false }
    }

    public func status() -> AgentStatus {
        dropExpired(now: Date())
        return AgentStatus(
            version: version,
            pid: getpid(),
            keys: listed.map { .init(name: $0.name, inMemory: open[$0.publicBlob] != nil) },
            memoryOnlyKeys: session.count,
            sessionBinds: sessionBinds,
            storeError: storeError?.description
        )
    }
}

/// What the agent reports through its status extension.
public struct AgentStatus: Codable, Sendable {
    public struct Key: Codable, Sendable {
        public let name: String
        public let inMemory: Bool
    }

    public let version: String
    public let pid: Int32
    public let keys: [Key]
    public let memoryOnlyKeys: Int
    public let sessionBinds: Int
    public let storeError: String?
}
