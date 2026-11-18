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

/// The token changed while a check ran, so the check stops before it writes anything else.
struct Stale: Error {}

/// Seals a private key into a stored key, as `KeychainStore.makeWrappedKey` does.
public typealias KeyWrapper = @Sendable (_ name: String, _ key: PrivateKey, _ comment: String, _ hosts: [String]) throws(StoreError) -> StoredKey

/// One check of design decision 5: reads 1Password and brings the stored keys, the `signd` note and the skipped items up to date.
struct SyncCheck {
    let source: any OnePasswordSource
    let store: any KeyStore
    let wrap: KeyWrapper
    /// This Mac's `LocalHostName`, in lowercase.
    let hostName: String
    /// Whether the token this check started with is still the agent's; asked before every write to the store.
    let isCurrent: @Sendable () -> Bool
    /// The running signd's version: an item its client could not read is read again by another version.
    let version: String

    /// Whether 1Password's client could not read an item's reply; that item is skipped and the rest are checked.
    static func isUndecodable(_ error: OnePasswordError) -> Bool {
        error.kind == .decoding
    }

    /// An item whose fetch has been read and whose key name another key may hold until this vault's renames and removals are done.
    typealias Deferred = (overview: ItemOverview, item: Item)

    /// Returns the state after the check; the keys are changed in the store as it goes.
    /// The service's isolation is part of the signature: no suspension separates `current()` from the write it guards,
    /// so a logout or a new login cannot run in between, and `@concurrent` cannot be added here without breaking that.
    func run(from old: SyncState, counters: inout Counters, changes: inout Changes, isolation _: isolated SyncService) async throws -> SyncState {
        counters.requests += 1
        let vaults = try await source.vaults()
        try current()
        let vaultIDs = Set(vaults.map(\.id))
        var keys = try store.list()

        for key in keys where key.isSynced && !(key.vaultID.map(vaultIDs.contains) ?? false) {
            try remove(key, keys: &keys, changes: &changes)
        }

        // A vault with an item that another signd version could not read is read again, as is a vault that changed.
        let reread = Set(old.skipped.filter { $0.kind != .invalidNote && $0.undecodedBy.map { $0 != version } ?? false }.map(\.vaultID))
        let moved = vaults.filter { old.vaultVersions[$0.id] != $0.contentVersion || reread.contains($0.id) }
        let movedIDs = Set(moved.map(\.id))
        var state = old
        state.vaultVersions = Dictionary(uniqueKeysWithValues: vaults.map { ($0.id, $0.contentVersion) })
        state.skipped = old.skipped.filter { vaultIDs.contains($0.vaultID) && ($0.kind == .invalidNote || !movedIDs.contains($0.vaultID)) }

        var notes: [(vaultID: String, overview: ItemOverview)] = []
        if let note = old.note, vaultIDs.contains(note.vaultID), !movedIDs.contains(note.vaultID) {
            notes.append((note.vaultID, ItemOverview(id: note.itemID, title: Selection.note, category: Selection.noteCategory, vaultId: note.vaultID, updatedAt: note.updated, state: "active")))
        }

        for vault in moved {
            counters.requests += 1
            let overviews = try await source.items(vaultID: vault.id).filter { $0.state == "active" }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
            if let note = overviews.first(where: { $0.category == Selection.noteCategory && $0.title == Selection.note }) {
                notes.append((vault.id, note))
            }
            var present = Set<String>()
            var deferred: [Deferred] = []
            for overview in overviews where overview.category == Selection.keyCategory {
                present.insert(overview.id)
                try await sync(overview, in: vault, old: old, state: &state, keys: &keys, counters: &counters, changes: &changes, deferred: &deferred)
            }
            for key in keys where key.isSynced && key.vaultID == vault.id && !present.contains(key.itemID ?? "") {
                try remove(key, keys: &keys, changes: &changes)
            }
            // Renames and removals are done, so a name that was taken may be free now.
            for entry in deferred {
                _ = try place(entry.item, overview: entry.overview, in: vault, state: &state, keys: &keys, changes: &changes, allowDefer: false)
            }
        }

        // A vault that did not change keeps its name conflicts with no request, until no key holds the name any more.
        let freed = state.skipped.filter { skip in
            skip.kind == .nameTaken && !movedIDs.contains(skip.vaultID) && !(skip.name.map { name in keys.contains { $0.name == name } } ?? false)
        }
        if !freed.isEmpty {
            state.skipped.removeAll { skip in freed.contains(skip) }
            let byID = Dictionary(uniqueKeysWithValues: vaults.map { ($0.id, $0) })
            var deferred: [(vault: VaultOverview, entry: Deferred)] = []
            for skip in freed {
                guard let vault = byID[skip.vaultID] else { continue }
                let overview = ItemOverview(id: skip.itemID, title: skip.title, category: Selection.keyCategory, vaultId: vault.id, updatedAt: skip.updated, state: "active")
                var held: [Deferred] = []
                try await read(overview, in: vault, state: &state, keys: &keys, counters: &counters, changes: &changes, deferred: &held)
                deferred += held.map { (vault, $0) }
            }
            for (vault, entry) in deferred {
                _ = try place(entry.item, overview: entry.overview, in: vault, state: &state, keys: &keys, changes: &changes, allowDefer: false)
            }
        }

        let order = Dictionary(uniqueKeysWithValues: vaults.enumerated().map { ($1.id, $0) })
        let note = notes.min { (order[$0.vaultID] ?? 0) < (order[$1.vaultID] ?? 0) }
        try await readNote(note, old: old, state: &state, counters: &counters)
        state.skipped.sort { ($0.title, $0.itemID) < ($1.title, $1.itemID) }
        return state
    }

    private func current() throws {
        if !isCurrent() { throw Stale() }
    }

    private func remove(_ key: StoredKey, keys: inout [StoredKey], changes: inout Changes) throws {
        try current()
        try store.delete(name: key.name)
        keys.removeAll { $0.name == key.name }
        changes.removed.append(key.name)
    }

    /// Reads one SSH Key item when it is new or changed, and brings its stored key up to date.
    private func sync(
        _ overview: ItemOverview, in vault: VaultOverview, old: SyncState, state: inout SyncState, keys: inout [StoredKey],
        counters: inout Counters, changes: inout Changes, deferred: inout [Deferred]
    ) async throws {
        let existing = keys.first { $0.isSynced && $0.vaultID == vault.id && $0.itemID == overview.id }
        if let existing, existing.itemUpdated == overview.updatedAt { return }
        // A name taken by another key can free up without the item changing, so that skip is read again.
        if let known = old.skipped.first(where: {
            $0.vaultID == vault.id && $0.itemID == overview.id && $0.updated == overview.updatedAt && $0.kind != .nameTaken
                && $0.undecodedBy.map { $0 == version } ?? true
        }) {
            state.skipped.append(known)
            return
        }
        try await read(overview, in: vault, state: &state, keys: &keys, counters: &counters, changes: &changes, deferred: &deferred)
    }

    /// Fetches one item and brings its stored key up to date, or skips it.
    private func read(
        _ overview: ItemOverview, in vault: VaultOverview, state: inout SyncState, keys: inout [StoredKey], counters: inout Counters,
        changes: inout Changes, deferred: inout [Deferred]
    ) async throws {
        counters.requests += 1
        counters.fetched += 1
        let item: Item
        do throws(OnePasswordError) {
            item = try await source.item(vaultID: vault.id, itemID: overview.id)
        } catch {
            guard Self.isUndecodable(error) else { throw error }
            // The client cannot read the item, which says nothing about the key it gave before, so that key stays.
            state.skipped.append(SkippedItem(
                vaultID: vault.id, itemID: overview.id, title: Selection.clean(overview.title), updated: overview.updatedAt, kind: .invalidKey,
                reason: "1Password's reply for this item could not be read", undecodedBy: version
            ))
            return
        }
        if try place(item, overview: overview, in: vault, state: &state, keys: &keys, changes: &changes, allowDefer: true) {
            deferred.append((overview, item))
        }
    }

    private func skip(
        _ overview: ItemOverview, in vault: VaultOverview, _ kind: SkipKind, _ reason: String, name: String? = nil, state: inout SyncState,
        keys: inout [StoredKey], changes: inout Changes
    ) throws {
        state.skipped.append(SkippedItem(
            vaultID: vault.id, itemID: overview.id, title: Selection.clean(overview.title), updated: overview.updatedAt, kind: kind,
            reason: Selection.clean(reason), name: name
        ))
        if let existing = keys.first(where: { $0.isSynced && $0.vaultID == vault.id && $0.itemID == overview.id }) {
            try remove(existing, keys: &keys, changes: &changes)
        }
    }

    /// Stores the key of a fetched item, or skips the item. With `allowDefer`, an item whose name another key holds is not skipped
    /// yet: it returns true, and waits for the end of its vault. Without it, that item is skipped.
    private func place(
        _ item: Item, overview: ItemOverview, in vault: VaultOverview, state: inout SyncState, keys: inout [StoredKey], changes: inout Changes,
        allowDefer: Bool
    ) throws -> Bool {
        let existing = keys.first { $0.isSynced && $0.vaultID == vault.id && $0.itemID == overview.id }
        switch Selection.read(item, hostName: hostName) {
        case let .skipped(kind, reason):
            try skip(overview, in: vault, kind, reason, state: &state, keys: &keys, changes: &changes)
            return false
        case let .key(privateKey, name, hosts):
            if let owner = keys.first(where: { $0.name == name }), owner.itemID != overview.id || !owner.isSynced || owner.vaultID != vault.id {
                if allowDefer { return true }
                try skip(overview, in: vault, .nameTaken, "the key name \(name) belongs to another key", name: name, state: &state, keys: &keys, changes: &changes)
                return false
            }
            let comment = Selection.clean(overview.title)
            let blob = privateKey.publicKey.blob
            if var kept = existing, kept.publicBlob == blob, kept.kind == .wrapped {
                // Only the item's other fields changed, so the sealed key stays.
                let oldName = kept.name
                kept.name = name
                kept.hosts = hosts
                kept.comment = comment
                kept.itemUpdated = overview.updatedAt
                try write(kept, replacing: oldName, keys: &keys, changes: &changes)
                return false
            }
            try current()
            var key = try wrap(name, privateKey, comment, hosts)
            key.vaultID = vault.id
            key.itemID = overview.id
            key.itemUpdated = overview.updatedAt
            try write(key, replacing: existing?.name, keys: &keys, changes: &changes)
            return false
        }
    }

    /// Stores `key`: one write over the key of the same name, or a delete and an add when the name changed.
    private func write(_ key: StoredKey, replacing oldName: String?, keys: inout [StoredKey], changes: inout Changes) throws {
        try current()
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
        let unreadable = old.skipped.contains { $0.kind == .invalidNote && $0.undecodedBy.map { $0 != version } ?? false }
        if old.note == reference && !unreadable { return }
        state.skipped.removeAll { $0.kind == .invalidNote }
        counters.requests += 1
        counters.fetched += 1
        let item: Item
        do throws(OnePasswordError) {
            item = try await source.item(vaultID: found.vaultID, itemID: found.overview.id)
        } catch {
            guard Self.isUndecodable(error) else { throw error }
            // The settings stay at their defaults until a signd version can read the note.
            state.fleet = [:]
            state.skipped.append(SkippedItem(
                vaultID: found.vaultID, itemID: found.overview.id, title: "\(Selection.note) note", updated: found.overview.updatedAt, kind: .invalidNote,
                reason: "the reply for the note could not be read, so the default settings apply", undecodedBy: version
            ))
            return
        }
        state.fleet = [:]
        for key in Settings.Key.allCases {
            guard let value = Selection.field(item, titled: key.rawValue), !value.isEmpty else { continue }
            if Settings.validSeconds(key, value) != nil {
                state.fleet[key.rawValue] = value
            } else {
                state.skipped.append(SkippedItem(
                    vaultID: found.vaultID, itemID: item.id, title: "\(Selection.note) note", updated: item.updatedAt, kind: .invalidNote,
                    reason: Selection.clean("\(key.rawValue) is \"\(value)\", not a duration such as 90s, 30m, 1h or 2d from \(key.bounds.lowerBound) to \(key.bounds.upperBound) seconds")
                ))
            }
        }
    }
}
