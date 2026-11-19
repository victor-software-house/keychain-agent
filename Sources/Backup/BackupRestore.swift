import Foundation
import KeyStore
import OnePassword
import SSHEncoding

/// A key of the backup that `signd backup restore` can import.
public struct BackupRestoreKey: Codable, Sendable, Equatable {
    public var name: String
    /// `BackupFormat.shared`, or the identifier of the Mac the key came from.
    public var scope: String
    public var fingerprint: String

    public init(name: String, scope: String, fingerprint: String) {
        self.name = name
        self.scope = scope
        self.fingerprint = fingerprint
    }
}

/// The keys of the backup, or why the vault could not be read.
public struct BackupRestoreList: Codable, Sendable, Equatable {
    public var keys: [BackupRestoreKey]
    /// Why the backup could not be read; nil when it was.
    public var failure: String?

    public init(keys: [BackupRestoreKey] = [], failure: String? = nil) {
        self.keys = keys
        self.failure = failure
    }
}

/// What a restore did with one key.
/// It contains no secret.
public struct RestoredKey: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case restored
        case skipped
        case failed
    }

    public var name: String
    public var outcome: Outcome
    public var reason: String?

    public init(name: String, outcome: Outcome, reason: String? = nil) {
        self.name = name
        self.outcome = outcome
        self.reason = reason
    }
}

/// What a restore did: one result per key, or why the backup itself failed.
public struct BackupRestoreResult: Codable, Sendable, Equatable {
    public var keys: [RestoredKey]
    /// Why the backup could not be read, such as no token; nil when it was.
    public var failure: String?

    public init(keys: [RestoredKey] = [], failure: String? = nil) {
        self.keys = keys
        self.failure = failure
    }
}

/// Seals a private key to a new Secure Enclave key of this Mac, as `KeychainStore.makeWrappedKey` does.
public typealias BackupKeyWrapper = @Sendable (_ name: String, _ key: PrivateKey, _ comment: String, _ hosts: [String]) throws(StoreError) -> StoredKey

/// Lists the keys of the backup vault and imports the ones picked, by design decision 7.
///
/// Only the agent calls it, so no command reads the token.
/// A Secure Enclave list item is not a key and is never listed or restored.
public struct BackupRestore: Sendable {
    public struct Dependencies: Sendable {
        /// Where this Mac keeps the backup token.
        public var tokens: any TokenStore
        public var openVault: BackupVaultOpener
        public var vault: @Sendable () -> String
        public var store: any KeyStorage
        public var wrap: BackupKeyWrapper

        public init(tokens: any TokenStore, openVault: @escaping BackupVaultOpener, vault: @escaping @Sendable () -> String, store: any KeyStorage, wrap: @escaping BackupKeyWrapper) {
            self.tokens = tokens
            self.openVault = openVault
            self.vault = vault
            self.store = store
            self.wrap = wrap
        }
    }

    private let dependencies: Dependencies

    public init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// One key item of the vault, as the `signd` section describes it.
    private struct Found {
        let name: String
        let scope: String
        let fingerprint: String
        let item: Item
    }

    /// The keys of the backup, by name and scope.
    /// It runs on the global executor, so no 1Password call runs on the agent actor or the event loop.
    @concurrent public func list() async -> BackupRestoreList {
        do {
            return BackupRestoreList(keys: try await found().map { BackupRestoreKey(name: $0.name, scope: $0.scope, fingerprint: $0.fingerprint) })
        } catch {
            return BackupRestoreList(failure: BackupRun.describe(error))
        }
    }

    /// Imports the keys named, or every key of the backup with `all`, into the store.
    /// A failure of the backup itself, such as no token, is the result's `failure`, with no key.
    @concurrent public func restore(names: [String], all: Bool) async -> BackupRestoreResult {
        let keys: [Found]
        let stored: [StoredKey]
        do {
            keys = try await found()
            stored = try dependencies.store.list()
        } catch {
            return BackupRestoreResult(failure: BackupRun.describe(error))
        }
        var fingerprints = Set(stored.compactMap { $0.publicKey?.fingerprint })
        var used = Set(stored.map(\.name))
        let byName = Dictionary(grouping: keys, by: \.name)
        var picked: [String] = []
        let wanted = all ? byName.keys.sorted() : names
        for name in wanted where !picked.contains(name) { picked.append(name) }

        var results: [RestoredKey] = []
        for name in picked {
            guard let matches = byName[name] else {
                results.append(RestoredKey(name: name, outcome: .failed, reason: "no item"))
                continue
            }
            guard matches.count == 1, let match = matches.first else {
                results.append(RestoredKey(name: name, outcome: .skipped, reason: "several items have this name"))
                continue
            }
            results.append(restore(match, fingerprints: &fingerprints, names: &used))
        }
        return BackupRestoreResult(keys: results)
    }

    /// The key items of the active, tagged items of the vault.
    /// Copies of one slot, as 1Password's Duplicate makes them, count once: the oldest.
    private func found() async throws -> [Found] {
        guard var token = try dependencies.tokens.read() else { throw BackupFailure("the backup is off; run signd backup login") }
        defer { token.resetBytes(in: 0..<token.count) }
        let vault = try await dependencies.openVault(String(decoding: token, as: UTF8.self), dependencies.vault())
        let ids = try await vault.list()
            .filter { $0.state == .active && $0.tags.contains(BackupFormat.tag) && BackupFormat.keyCategories.contains($0.category) }
            .map(\.id)
        var copies: [BackupSlot: Found] = [:]
        for start in stride(from: 0, to: ids.count, by: BackupPlanner.fetchBatch) {
            for result in try await vault.items(Array(ids[start..<min(start + BackupPlanner.fetchBatch, ids.count)])) {
                guard case let .item(item) = result, let owner = BackupOwner(item: item), owner.slot.kind == .key,
                    let name = owner.name, let fingerprint = owner.slot.fingerprint
                else { continue }
                if let existing = copies[owner.slot], (existing.item.updatedAt, existing.item.id) <= (item.updatedAt, item.id) { continue }
                copies[owner.slot] = Found(name: name, scope: owner.slot.scope, fingerprint: fingerprint, item: item)
            }
        }
        return copies.values.sorted { ($0.name, $0.scope) < ($1.name, $1.scope) }
    }

    /// Imports one key, and records its fingerprint and name so a later item of the same restore sees them.
    private func restore(_ key: Found, fingerprints: inout Set<String>, names: inout Set<String>) -> RestoredKey {
        func result(_ outcome: RestoredKey.Outcome, _ reason: String? = nil) -> RestoredKey {
            RestoredKey(name: key.name, outcome: outcome, reason: reason)
        }
        func text(_ title: String) -> String {
            key.item.fields.first { $0.title == title && BackupFormat.isTopLevel($0) }?.value ?? ""
        }
        guard !fingerprints.contains(key.fingerprint) else { return result(.skipped, "already stored") }
        guard !names.contains(key.name) else { return result(.skipped, "the name is taken") }
        guard StoredKey.isValidName(key.name) else { return result(.failed, "the name is not valid") }
        let hosts = text("hosts").split(whereSeparator: \.isWhitespace).map(String.init)
        guard hosts.allSatisfy(StoredKey.isValidHost) else { return result(.failed, "a host pattern is not valid") }
        let secret = text("private key")
        guard !secret.isEmpty else { return result(.failed, "the item has no private key") }

        var bytes = Data(secret.utf8)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        let imported: ImportedKey
        do {
            imported = try KeyImport.parse(bytes)
        } catch {
            return result(.failed, BackupRun.describe(error))
        }
        guard case let .key(privateKey, own) = imported else { return result(.failed, "the key is encrypted with a passphrase") }
        guard privateKey.publicKey.fingerprint == key.fingerprint else { return result(.failed, "the key does not match its fingerprint") }
        let comment = text("comment")
        do throws(StoreError) {
            try dependencies.store.add(try dependencies.wrap(key.name, privateKey, comment.isEmpty ? own : comment, hosts))
        } catch {
            if case .duplicate = error { return result(.skipped, "the name is taken") }
            return result(.failed, BackupRun.describe(error))
        }
        fingerprints.insert(key.fingerprint)
        names.insert(key.name)
        return result(.restored)
    }
}
