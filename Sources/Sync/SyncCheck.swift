import Foundation
import KeyStore
import OnePassword
import SSHWire

/// Request counts of one check, kept outside `SyncCheck.run` so a failed check still reports them.
struct Counters: Sendable {
    var requests = 0
    var fetched = 0
}

/// What a check changed in the store, by key name.
struct Changes: Sendable {
    var added: [String] = []
    var replaced: [String] = []
    var removed: [String] = []

    var isEmpty: Bool { added.isEmpty && replaced.isEmpty && removed.isEmpty }
}

/// Seals a private key into a stored key, as `KeychainStore.makeWrappedKey` does.
public typealias KeyWrapper = @Sendable (_ name: String, _ key: PrivateKey, _ comment: String, _ hosts: [String]) throws(StoreError) -> StoredKey

/// One check of design decision 5: reads 1Password and brings the stored keys, the `signd` note and the skipped items up to date.
struct SyncCheck {
    let source: any OnePasswordSource
    let store: any KeyStore
    let wrap: KeyWrapper
    /// This Mac's `LocalHostName`, in lowercase.
    let hostName: String

    /// Returns the state after the check; the keys are changed in the store as it goes, and the vault versions move only when it ends.
    func run(from old: SyncState, counters: inout Counters, changes: inout Changes) async throws -> SyncState {
        counters.requests += 1
        let vaults = try await source.vaults()
        let vaultIDs = Set(vaults.map(\.id))
        var keys = try store.list()

        for key in keys where key.isSynced && !(key.vaultID.map(vaultIDs.contains) ?? false) {
            try store.delete(name: key.name)
            changes.removed.append(key.name)
        }
        keys.removeAll { $0.isSynced && !($0.vaultID.map(vaultIDs.contains) ?? false) }

        let moved = vaults.filter { old.vaultVersions[$0.id] != $0.contentVersion }
        var state = old
        state.vaultVersions = Dictionary(uniqueKeysWithValues: vaults.map { ($0.id, $0.contentVersion) })
        let movedIDs = Set(moved.map(\.id))
        state.skipped = old.skipped.filter { vaultIDs.contains($0.vaultID) && ($0.kind == .invalidNote || !movedIDs.contains($0.vaultID)) }

        var notes: [(vaultID: String, overview: ItemOverview)] = []
        if let note = old.note, vaultIDs.contains(note.vaultID), !moved.contains(where: { $0.id == note.vaultID }) {
            notes.append((note.vaultID, ItemOverview(id: note.itemID, title: Selection.note, category: Selection.noteCategory, vaultId: note.vaultID, updatedAt: note.updated, state: "active")))
        }

        for vault in moved {
            counters.requests += 1
            let overviews = try await source.items(vaultID: vault.id).filter { $0.state == "active" }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
            if let note = overviews.first(where: { $0.category == Selection.noteCategory && $0.title == Selection.note }) {
                notes.append((vault.id, note))
            }
            var present = Set<String>()
            for overview in overviews where overview.category == Selection.keyCategory {
                present.insert(overview.id)
                try await sync(overview, in: vault, old: old, state: &state, keys: &keys, counters: &counters, changes: &changes)
            }
            for key in keys where key.isSynced && key.vaultID == vault.id && !present.contains(key.itemID ?? "") {
                try remove(key, keys: &keys, changes: &changes)
            }
        }

        let order = Dictionary(uniqueKeysWithValues: vaults.enumerated().map { ($1.id, $0) })
        let note = notes.min { (order[$0.vaultID] ?? 0) < (order[$1.vaultID] ?? 0) }
        try await readNote(note, old: old, state: &state, counters: &counters)
        state.skipped.sort { ($0.title, $0.itemID) < ($1.title, $1.itemID) }
        return state
    }

    private func remove(_ key: StoredKey, keys: inout [StoredKey], changes: inout Changes) throws {
        try store.delete(name: key.name)
        keys.removeAll { $0.name == key.name }
        changes.removed.append(key.name)
    }

    /// Brings one SSH Key item's stored key up to date, reading the item only when it is new or changed.
    private func sync(
        _ overview: ItemOverview, in vault: VaultOverview, old: SyncState, state: inout SyncState, keys: inout [StoredKey],
        counters: inout Counters, changes: inout Changes
    ) async throws {
        let existing = keys.first { $0.isSynced && $0.vaultID == vault.id && $0.itemID == overview.id }
        if let existing, existing.itemUpdated == overview.updatedAt { return }
        // A name taken by another key can free up without the item changing, so that skip is read again.
        if let known = old.skipped.first(where: { $0.vaultID == vault.id && $0.itemID == overview.id && $0.updated == overview.updatedAt && $0.kind != .nameTaken }) {
            state.skipped.append(known)
            return
        }
        counters.requests += 1
        counters.fetched += 1
        let item = try await source.item(vaultID: vault.id, itemID: overview.id)

        func skip(_ kind: SkipKind, _ reason: String) throws {
            state.skipped.append(SkippedItem(vaultID: vault.id, itemID: overview.id, title: overview.title, updated: overview.updatedAt, kind: kind, reason: reason))
            if let existing { try remove(existing, keys: &keys, changes: &changes) }
        }

        switch Selection.read(item, hostName: hostName) {
        case let .skipped(kind, reason):
            try skip(kind, reason)
        case let .key(privateKey, name, hosts):
            if let owner = keys.first(where: { $0.name == name }), owner.itemID != overview.id || !owner.isSynced || owner.vaultID != vault.id {
                try skip(.nameTaken, "the key name \(name) belongs to another key")
                return
            }
            let blob = privateKey.publicKey.blob
            if var kept = existing, kept.publicBlob == blob, kept.kind == .wrapped {
                // Only the item's other fields changed, so the sealed key stays.
                let oldName = kept.name
                kept.name = name
                kept.hosts = hosts
                kept.comment = overview.title
                kept.itemUpdated = overview.updatedAt
                try write(kept, replacing: oldName, keys: &keys, changes: &changes)
                return
            }
            var key = try wrap(name, privateKey, overview.title, hosts)
            key.vaultID = vault.id
            key.itemID = overview.id
            key.itemUpdated = overview.updatedAt
            try write(key, replacing: existing?.name, keys: &keys, changes: &changes)
        }
    }

    /// Stores `key`: one write over the key of the same name, or a delete and an add when the name changed.
    private func write(_ key: StoredKey, replacing oldName: String?, keys: inout [StoredKey], changes: inout Changes) throws {
        switch oldName {
        case key.name?:
            try store.replace(key)
            keys.removeAll { $0.name == key.name }
            keys.append(key)
            changes.replaced.append(key.name)
        case let oldName?:
            try store.delete(name: oldName)
            try store.add(key)
            keys.removeAll { $0.name == oldName }
            keys.append(key)
            changes.replaced.append(key.name)
        case nil:
            try store.add(key)
            keys.append(key)
            changes.added.append(key.name)
        }
    }

    /// Reads the `signd` note when it is new or changed, and keeps its settings.
    private func readNote(_ found: (vaultID: String, overview: ItemOverview)?, old: SyncState, state: inout SyncState, counters: inout Counters) async throws {
        guard let found else {
            state.note = nil
            state.fleet = [:]
            state.skipped.removeAll { $0.kind == .invalidNote }
            return
        }
        let reference = NoteRef(vaultID: found.vaultID, itemID: found.overview.id, updated: found.overview.updatedAt)
        state.note = reference
        if old.note == reference { return }
        state.skipped.removeAll { $0.kind == .invalidNote }
        counters.requests += 1
        counters.fetched += 1
        let item = try await source.item(vaultID: found.vaultID, itemID: found.overview.id)
        state.fleet = [:]
        for key in [Settings.Key.interval, .keyLifetime] {
            guard let value = Selection.field(item, titled: key.rawValue), !value.isEmpty else { continue }
            if Settings.validSeconds(key, value) != nil {
                state.fleet[key.rawValue] = value
            } else {
                state.skipped.append(SkippedItem(
                    vaultID: found.vaultID, itemID: item.id, title: "\(Selection.note) note", updated: item.updatedAt, kind: .invalidNote,
                    reason: "\(key.rawValue) is \"\(value)\", not a duration such as 90s, 30m, 1h or 2d"
                ))
            }
        }
    }
}
