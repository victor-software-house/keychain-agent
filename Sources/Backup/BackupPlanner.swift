import Foundation
import OnePassword
import Sync

/// What a run does with the items of a removed key, by the `backup-removed` setting.
public enum BackupRemoved: String, CaseIterable, Sendable {
    case delete
    case archive
    case keep
}

/// How the read of the `Key` and `Device` records ended.
public enum BackupRead: Sendable, Equatable {
    /// A full zone fetch, started with no change token, that returned every page.
    case completeFull
    /// A failed, partial or incremental read, which decides no removal.
    case incomplete(reason: String)
}

/// What a run plans from.
public struct BackupSources: Sendable {
    /// The shared keys of the `Key` records the read returned.
    public var shared: [BackupKey]
    public var read: BackupRead
    /// This Mac's keys that are not shared.
    public var local: [BackupKey]
    /// This Mac's Secure Enclave keys.
    public var secureEnclave: [BackupSecureEnclaveKey]
    /// The change tag of the Secure Enclave list's source.
    public var secureEnclaveTag: String
    /// This Mac's device identifier and name.
    public var deviceID: String
    public var deviceName: String
    /// The device identifiers of the `Device` records the read returned.
    public var devices: Set<String>
    /// The records the read could not return.
    public var unreadable: [UnreadableRecord]
    /// The fingerprint of every key in this Mac's store, whatever its scope.
    public var storeFingerprints: Set<String>

    public init(
        shared: [BackupKey], read: BackupRead, local: [BackupKey], secureEnclave: [BackupSecureEnclaveKey], secureEnclaveTag: String,
        deviceID: String, deviceName: String, devices: Set<String>, unreadable: [UnreadableRecord], storeFingerprints: Set<String>
    ) {
        self.shared = shared
        self.read = read
        self.local = local
        self.secureEnclave = secureEnclave
        self.secureEnclaveTag = secureEnclaveTag
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.devices = devices
        self.unreadable = unreadable
        self.storeFingerprints = storeFingerprints
    }
}

/// What a run does to the vault.
public struct BackupPlan: Sendable, Equatable {
    public struct Put: Sendable, Equatable {
        public let itemID: String
        public let desired: BackupDesiredItem
    }

    /// Item IDs to read with `getAll`, 50 a call.
    /// When it is not empty, the rest of the plan is empty: read them, and plan again with them.
    public var fetch: [[String]] = []
    /// Items to create, 100 a call.
    public var create: [[BackupDesiredItem]] = []
    public var put: [Put] = []
    /// Items to delete, 50 a call.
    public var delete: [[String]] = []
    public var archive: [String] = []
    /// Items of removed keys that `backup-removed` leaves in the vault.
    public var keep: [String] = []
    /// The fingerprints of keys this Mac cannot read the private key of, which get no item.
    public var unavailable: [String] = []
    /// Why no item is removed, when the read did not decide removals.
    public var skippedRemovals: String?
    /// The cache entries that this plan leaves as they are, by item ID.
    /// The items it creates, puts, deletes or archives are not in it: the run records them after the call.
    public var cache: [String: BackupCacheEntry] = [:]

    public init() {}

    /// Whether the run needs nothing beyond the list call.
    public var isIdle: Bool { fetch.isEmpty && create.isEmpty && put.isEmpty && delete.isEmpty && archive.isEmpty }
}

/// Plans a run from the sources and the vault, with no call to 1Password or CloudKit.
public enum BackupPlanner {
    public static let fetchBatch = 50
    public static let createBatch = 100
    public static let deleteBatch = 50

    /// One active tagged item of the vault, as the plan reads it.
    private struct Known {
        let id: String
        let updatedAt: Date
        let owner: BackupOwner?
        /// The full item, when this run has it.
        let item: Item?
        let cachedTag: String?
    }

    /// Plans a run.
    /// `overviews` are the vault's list; `items` are full items of it that a run read for the IDs in an earlier `plan.fetch`.
    /// An item the list shows that is tagged, and is in neither `items` nor a current `cache` entry, goes to `plan.fetch`.
    public static func plan(
        sources: BackupSources, overviews: [ItemOverview], items: [Item], cache: [String: BackupCacheEntry], removed: BackupRemoved
    ) -> BackupPlan {
        let fetched = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var known: [Known] = []
        var missing: [String] = []
        for overview in overviews where overview.state == .active && overview.tags.contains(BackupFormat.tag) {
            if let item = fetched[overview.id] {
                known.append(Known(id: item.id, updatedAt: item.updatedAt, owner: BackupOwner(item: item), item: item, cachedTag: nil))
            } else if let entry = cache[overview.id], entry.updatedAt == overview.updatedAt {
                known.append(Known(id: entry.id, updatedAt: entry.updatedAt, owner: entry.owner, item: nil, cachedTag: entry.sourceTag))
            } else {
                missing.append(overview.id)
            }
        }
        var plan = BackupPlan()
        guard missing.isEmpty else {
            plan.fetch = chunks(missing, fetchBatch)
            return plan
        }

        let (desired, unavailable) = desiredItems(sources, existingList: known.contains { $0.owner?.slot == BackupSlot.list(device: sources.deviceID) })
        plan.unavailable = unavailable
        var groups: [BackupSlot: [Known]] = [:]
        for entry in known {
            if let owner = entry.owner { groups[owner.slot, default: []].append(entry) }
        }
        groups = groups.mapValues { copies in copies.sorted { left, right in (left.updatedAt, left.id) < (right.updatedAt, right.id) } }

        var created: [BackupDesiredItem] = []
        var touched: Set<String> = []
        for want in desired {
            // A duplicate leaves the oldest copy to update and the others alone.
            guard let target = groups[want.slot]?.first else {
                created.append(want)
                continue
            }
            let current = target.item.map(want.matches) ?? (target.cachedTag == want.changeTag)
            if current {
                plan.cache[target.id] = BackupCacheEntry(id: target.id, updatedAt: target.updatedAt, owner: target.owner, sourceTag: want.changeTag)
            } else {
                plan.put.append(BackupPlan.Put(itemID: target.id, desired: want))
                touched.insert(target.id)
            }
        }
        plan.create = chunks(created, createBatch)

        if case let .incomplete(reason) = sources.read {
            plan.skippedRemovals = reason
        } else {
            let wanted = Set(desired.map(\.slot))
            var ids: [String] = []
            for slot in groups.keys.sorted(by: order) where !wanted.contains(slot) {
                guard let copies = groups[slot], isRemovable(slot, copies: copies, sources: sources) else { continue }
                ids += copies.map(\.id)
            }
            switch removed {
            case .delete:
                plan.delete = chunks(ids, deleteBatch)
                touched.formUnion(ids)
            case .archive:
                plan.archive = ids
                touched.formUnion(ids)
            case .keep:
                plan.keep = ids
            }
        }

        for entry in known where !touched.contains(entry.id) && plan.cache[entry.id] == nil {
            plan.cache[entry.id] = BackupCacheEntry(id: entry.id, updatedAt: entry.updatedAt, owner: entry.owner, sourceTag: entry.cachedTag)
        }
        return plan
    }

    /// The items this Mac writes, and the fingerprints of keys with no private key to write.
    /// A Secure Enclave list is wanted when this Mac has such keys, or already has a list item to keep current.
    private static func desiredItems(_ sources: BackupSources, existingList: Bool) -> (items: [BackupDesiredItem], unavailable: [String]) {
        var items: [BackupDesiredItem] = []
        var unavailable: [String] = []
        for (keys, scope) in [(sources.shared, BackupFormat.shared), (sources.local, sources.deviceID)] {
            var seen: Set<String> = []
            // Two keys with one fingerprint share an item; the first by name gives it.
            for key in keys.sorted(by: { $0.name < $1.name }) where seen.insert(key.fingerprint).inserted {
                if let item = BackupDesiredItem(key: key, scope: scope) {
                    items.append(item)
                } else {
                    unavailable.append(key.fingerprint)
                }
            }
        }
        if !sources.secureEnclave.isEmpty || existingList {
            items.append(BackupDesiredItem(secureEnclave: sources.secureEnclave, device: sources.deviceID, deviceName: sources.deviceName, changeTag: sources.secureEnclaveTag))
        }
        return (items, unavailable)
    }

    /// Whether this Mac may remove the items of `slot`, which no source lists.
    /// It never removes an item of another Mac's local key, or the list of its own Mac.
    private static func isRemovable(_ slot: BackupSlot, copies: [Known], sources: BackupSources) -> Bool {
        switch slot.kind {
        case .key:
            guard let fingerprint = slot.fingerprint, !sources.storeFingerprints.contains(fingerprint) else { return false }
            if slot.scope == BackupFormat.shared {
                let unreadable = Set(sources.unreadable.filter { $0.type == .key }.map(\.name))
                // A key whose record could not be read is not listed, and is not gone.
                let unread = copies.contains { copy in copy.owner?.name.map { unreadable.contains(KeyPayload.recordName(for: $0)) } ?? false }
                return !unread && !sources.shared.contains { $0.fingerprint == fingerprint }
            }
            return slot.scope == sources.deviceID
        case .secureEnclaveList:
            let unreadable = Set(sources.unreadable.filter { $0.type == .device }.map(\.name))
            return slot.scope != sources.deviceID && !sources.devices.contains(slot.scope) && !unreadable.contains(slot.scope)
        }
    }

    private static func order(_ left: BackupSlot, _ right: BackupSlot) -> Bool {
        (left.kind.rawValue, left.scope, left.fingerprint ?? "") < (right.kind.rawValue, right.scope, right.fingerprint ?? "")
    }

    private static func chunks<Element>(_ elements: [Element], _ size: Int) -> [[Element]] {
        stride(from: 0, to: elements.count, by: size).map { Array(elements[$0..<min($0 + size, elements.count)]) }
    }
}
