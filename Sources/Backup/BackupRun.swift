import CryptoKit
import Dispatch
import Foundation
import KeyStore
import OnePassword
import os
import SSHWire
import Sync

private let log = Logger(subsystem: "com.victor-software-house.signd", category: "backup")

/// The renewal of the lease failed, so another Mac may run the backup now and this run stops before its next batch.
struct LeaseLost: Error, CustomStringConvertible {
    let reason: String
    var description: String { "the backup lease was lost: \(reason)" }
}

/// One backup run, from the lease to the cache, by design decisions 3 to 5.
///
/// A run reads what each scope is planned from, and plans.
/// The run reads the items the plan lists to fetch, plans again, and writes in the planner's batches.
/// The lease is renewed before each batch of writes, and before any call once a third of the lease has passed since the last renewal.
///
/// A run stops when a renewal fails.
public struct BackupRun: Sendable {
    public struct Dependencies: Sendable {
        public var cloud: any CloudStore
        public var store: any KeyStore
        /// Where this Mac keeps the backup token.
        public var tokens: any TokenStore
        public var device: @Sendable () throws(StoreError) -> DeviceKey
        public var deviceName: @Sendable () -> String
        /// Opens a stored wrapped key to its private key.
        public var open: KeyOpener
        public var openVault: BackupVaultOpener
        public var removed: @Sendable () -> BackupRemoved
        public var now: @Sendable () -> Date
        public var cacheURL: URL

        public init(
            cloud: any CloudStore, store: any KeyStore, tokens: any TokenStore, device: @escaping @Sendable () throws(StoreError) -> DeviceKey,
            deviceName: @escaping @Sendable () -> String = { ThisDevice.name() }, open: @escaping KeyOpener, openVault: @escaping BackupVaultOpener,
            removed: @escaping @Sendable () -> BackupRemoved, now: @escaping @Sendable () -> Date = { Date() }, cacheURL: URL = BackupCache.defaultURL
        ) {
            self.cloud = cloud
            self.store = store
            self.tokens = tokens
            self.device = device
            self.deviceName = deviceName
            self.open = open
            self.openVault = openVault
            self.removed = removed
            self.now = now
            self.cacheURL = cacheURL
        }
    }

    /// The puts and archives that share one renewal of the lease.
    static let writeGroup = 50

    private let dependencies: Dependencies

    public init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Runs the backup once.
    /// It runs on the global executor, so no 1Password or signing call runs on the agent actor or the event loop.
    @concurrent public func perform() async -> BackupResult {
        var token: Data
        do {
            guard let stored = try dependencies.tokens.read() else { return BackupResult(.off) }
            token = stored
        } catch {
            return BackupResult(.failed, "cannot read the backup token: \(Self.describe(error))")
        }
        defer { token.resetBytes(in: 0..<token.count) }
        let device: DeviceKey
        do {
            device = try dependencies.device()
        } catch {
            return BackupResult(.failed, "cannot read this Mac's device key: \(Self.describe(error))")
        }
        var lease = BackupLease(cloud: dependencies.cloud, holder: device.recordName, now: dependencies.now)
        do {
            guard try await lease.claim() == .acquired else { return BackupResult(.held, "another Mac holds the backup lease") }
        } catch {
            return BackupResult(.failed, "cannot claim the backup lease: \(Self.describe(error))")
        }
        let result: BackupResult
        var lost = false
        do {
            result = try await execute(token: token, device: device, lease: &lease)
        } catch let error as LeaseLost {
            result = BackupResult(.failed, error.description)
            lost = true
        } catch {
            result = BackupResult(.failed, Self.describe(error))
        }
        // A lost lease belongs to another Mac now, and a clear would find that out only by failing.
        if !lost { await lease.clear() }
        if let message = result.message { log.notice("run \(result.outcome.rawValue, privacy: .public): \(message, privacy: .public)") }
        return result
    }

    private func execute(token: Data, device: DeviceKey, lease: inout BackupLease) async throws -> BackupResult {
        let gathered = try await gather(device: device)
        try await renew(&lease, onlyIfDue: true)
        let vault = try await dependencies.openVault(String(decoding: token, as: UTF8.self), gathered.vault)
        try await renew(&lease, onlyIfDue: true)
        let overviews = try await vault.list()
        let loaded = BackupCache.load(from: dependencies.cacheURL)
        let removed = dependencies.removed()
        var plan = BackupPlanner.plan(sources: gathered.sources, overviews: overviews, items: [], cache: loaded, removed: removed)
        if !plan.fetch.isEmpty {
            var items: [Item] = []
            var unread: [String] = []
            for batch in plan.fetch {
                try await renew(&lease, onlyIfDue: true)
                let results = try await vault.items(batch)
                // A result names its item, and a failure names nothing, so a request is read when its item came back.
                let returned = Dictionary(results.compactMap { Self.item(of: $0) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for id in batch {
                    if let item = returned[id] {
                        items.append(item)
                    } else {
                        unread.append(id)
                    }
                }
            }
            plan = BackupPlanner.plan(sources: gathered.sources, overviews: overviews, items: items, unread: unread, cache: loaded, removed: removed)
            guard plan.fetch.isEmpty else { throw BackupFailure("the plan still asks for item reads after they were made") }
        }

        var written: [String: BackupCacheEntry] = [:]
        var rejected = Rejections()
        var stopped: (any Error)?
        do {
            try await write(plan, to: vault, lease: &lease, written: &written, rejected: &rejected)
        } catch {
            stopped = error
        }
        // The cache records what the batches wrote before a stop, so the next run reads fewer items.
        let cache = plan.cache.merging(written) { _, new in new }
        if cache != loaded {
            do {
                try BackupCache.save(cache, to: dependencies.cacheURL)
            } catch {
                log.error("cannot write the backup cache: \(Self.describe(error), privacy: .public)")
            }
        }
        if let stopped { throw stopped }

        var problems: [String] = []
        if case let .incomplete(reason) = gathered.sources.read { problems.append("the CloudKit read did not complete, so no item was removed: \(reason)") }
        if !plan.unread.isEmpty { problems.append("\(plan.unread.count) of the vault's items could not be read, so no item was created") }
        if rejected.count > 0 { problems.append(rejected.summary) }
        return problems.isEmpty ? BackupResult(.ok) : BackupResult(.failed, problems.joined(separator: "; "))
    }

    /// Creates, puts, deletes and archives in the planner's batches, and renews the lease before each.
    private func write(
        _ plan: BackupPlan, to vault: any BackupVault, lease: inout BackupLease, written: inout [String: BackupCacheEntry], rejected: inout Rejections
    ) async throws {
        for batch in plan.create {
            try await renew(&lease)
            let results = try await vault.create(batch.map(\.content))
            // A created item goes with the request of its slot, so the order of the results decides nothing.
            let wants = Dictionary(batch.map { ($0.slot, $0) }, uniquingKeysWith: { first, _ in first })
            var matched: Set<BackupSlot> = []
            for result in results {
                guard let item = Self.item(of: result), let slot = BackupOwner(item: item)?.slot, let want = wants[slot], matched.insert(slot).inserted else { continue }
                written[item.id] = BackupCacheEntry(item: item, sourceTag: want.changeTag)
            }
            rejected.count += batch.count - matched.count
        }
        for group in Self.groups(plan.put) {
            try await renew(&lease)
            for put in group {
                try await renew(&lease, onlyIfDue: true)
                do {
                    let item = try await vault.put(put.itemID, put.desired.content)
                    written[item.id] = BackupCacheEntry(item: item, sourceTag: put.desired.changeTag, target: item.id)
                } catch {
                    rejected.add("put \(put.itemID): \(Self.describe(error))")
                    log.error("cannot write item \(put.itemID, privacy: .public): \(Self.describe(error), privacy: .public)")
                }
            }
        }
        for batch in plan.delete {
            try await renew(&lease)
            let failures = try await vault.delete(batch)
            for (id, failure) in failures.sorted(by: { $0.key < $1.key }) { rejected.add("delete \(id): \(failure.rawValue)") }
        }
        for group in Self.groups(plan.archive) {
            try await renew(&lease)
            for id in group {
                try await renew(&lease, onlyIfDue: true)
                do {
                    try await vault.archive(id)
                } catch {
                    rejected.add("archive \(id): \(Self.describe(error))")
                    log.error("cannot archive item \(id, privacy: .public): \(Self.describe(error), privacy: .public)")
                }
            }
        }
    }

    /// Renews the lease, or with `onlyIfDue` only when a third of its length has passed since the last renewal.
    private func renew(_ lease: inout BackupLease, onlyIfDue: Bool = false) async throws {
        do {
            if onlyIfDue {
                try await lease.renewIfDue()
            } else {
                try await lease.renew()
            }
        } catch {
            throw LeaseLost(reason: Self.describe(error))
        }
    }

    private static func item(of result: ItemResult) -> Item? {
        if case let .item(item) = result { item } else { nil }
    }

    private static func groups<Element>(_ elements: [Element]) -> [[Element]] {
        stride(from: 0, to: elements.count, by: writeGroup).map { Array(elements[$0..<min($0 + writeGroup, elements.count)]) }
    }

    // MARK: Sources

    private struct Gathered {
        var sources: BackupSources
        /// The vault the `Backup` record names.
        var vault: String
    }

    /// Reads what the plan needs: a full CloudKit read for the shared keys, and this Mac's own store for the rest.
    private func gather(device: DeviceKey) async throws -> Gathered {
        let stored = try dependencies.store.list()
        var read = BackupRead.completeFull
        var records: [CloudRecord] = []
        var unreadable: [UnreadableRecord] = []
        do {
            let fetched = try await dependencies.cloud.changes(database: nil, zone: nil)
            if fetched.zoneLoss != nil {
                read = .incomplete(reason: "the signd zone was deleted in iCloud")
            } else if fetched.zoneToken == nil {
                read = .incomplete(reason: "iCloud did not return the zone")
            }
            records = fetched.changed
            unreadable = fetched.unreadable
        } catch {
            read = .incomplete(reason: Self.describe(error))
        }

        let byRecord = Dictionary(stored.compactMap { key in key.recordName.map { ($0, key) } }, uniquingKeysWith: { first, _ in first })
        var shared: [BackupKey] = []
        var devices: Set<String> = []
        var vault: String?
        for record in records {
            switch record.type {
            case .key:
                guard let payload = try? Payload.decode(KeyPayload.self, from: record.payload), record.name == KeyPayload.recordName(for: payload.name),
                    let publicKey = PublicKey(blob: payload.publicKey)
                else {
                    unreadable.append(UnreadableRecord(type: .key, name: record.name))
                    continue
                }
                // A shared key this Mac has no private key for still goes in, so its item stays.
                // The local key is the record's key only when both have one public key; a record changed elsewhere has no private key here yet.
                var privateKey: String?
                if let local = byRecord[record.name], local.kind == .wrapped, local.publicBlob == payload.publicKey { privateKey = await armor(local) }
                shared.append(
                    BackupKey(
                        name: payload.name, publicKey: publicKey, comment: payload.comment, hosts: payload.hosts, privateKey: privateKey,
                        changeTag: Self.tag([payload.name, payload.comment, payload.hosts.joined(separator: " "), payload.publicKey.base64EncodedString()])
                    )
                )
            case .device:
                if (try? Payload.decode(DevicePayload.self, from: record.payload)) != nil {
                    devices.insert(record.name)
                } else {
                    unreadable.append(UnreadableRecord(type: .device, name: record.name))
                }
            case .backup:
                if record.name == BackupPayload.recordName, let payload = try? Payload.decode(BackupPayload.self, from: record.payload) { vault = payload.vault }
            case .lease:
                break
            }
        }
        guard let vault else {
            if case let .incomplete(reason) = read { throw BackupFailure("cannot read the backup login: \(reason)") }
            throw BackupFailure("iCloud has no readable backup login")
        }

        var local: [BackupKey] = []
        var enclave: [BackupSecureEnclaveKey] = []
        for key in stored.sorted(by: { $0.name < $1.name }) {
            guard let publicKey = key.publicKey else { continue }
            switch key.kind {
            case .wrapped where !key.isShared:
                local.append(
                    BackupKey(
                        name: key.name, publicKey: publicKey, comment: key.comment, hosts: key.hosts, privateKey: await armor(key),
                        changeTag: Self.tag([key.name, key.comment, key.hosts.joined(separator: " "), key.publicBlob.base64EncodedString()])
                    )
                )
            case .secureEnclave:
                enclave.append(BackupSecureEnclaveKey(name: key.name, publicKey: publicKey.openSSHLine(comment: key.displayComment), hosts: key.hosts))
            case .wrapped:
                break
            }
        }
        let sources = BackupSources(
            shared: shared, read: read, local: local, secureEnclave: enclave,
            secureEnclaveTag: Self.tag(enclave.flatMap { [$0.name, $0.publicKey, $0.hosts.joined(separator: " ")] }),
            deviceID: device.recordName, deviceName: dependencies.deviceName(), devices: devices, unreadable: unreadable,
            storeFingerprints: Set(stored.compactMap { $0.publicKey?.fingerprint })
        )
        return Gathered(sources: sources, vault: vault)
    }

    /// The key as an OpenSSH private key file, or nil when this Mac cannot open it.
    /// Opening runs on a dispatch queue, so a slow Secure Enclave call never blocks the actor or the event loop.
    private func armor(_ key: StoredKey) async -> String? {
        let opener = dependencies.open
        do {
            return try await Self.offActor { () throws -> String in
                let (privateKey, comment) = try opener(key)
                return OpenSSHKeyFile.armored(privateKey, comment: comment)
            }
        } catch {
            log.error("cannot open \(key.name, privacy: .public) for the backup: \(Self.describe(error), privacy: .public)")
            return nil
        }
    }

    private static func offActor<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// A change tag for what an item shows of a key.
    /// It changes with the name, comment, hosts or public key, and not when a Mac seals the key.
    private static func tag(_ fields: [String]) -> String {
        SHA256.hash(data: Data(fields.joined(separator: "\u{1F}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// An error as the status and the log show it.
    /// A 1Password error shows only its code, because its message could echo a field value of an item, such as the private key.
    private static func describe(_ error: any Error) -> String {
        if let failure = error as? OnePasswordError { return "1Password \(failure.code.rawValue)" }
        return Display.clean(String(describing: error))
    }

    /// The writes a vault refused: how many, and the first few as the call, the item and the error code.
    private struct Rejections {
        private static let shown = 5
        var count = 0
        private var details: [String] = []

        mutating func add(_ detail: String) {
            count += 1
            details.append(detail)
        }

        var summary: String {
            guard !details.isEmpty else { return "writes the vault rejected: \(count)" }
            let listed = details.prefix(Self.shown)
            let more = count > listed.count ? "; and \(count - listed.count) more" : ""
            return "writes the vault rejected: \(count) (\(listed.joined(separator: "; "))\(more))"
        }
    }
}
