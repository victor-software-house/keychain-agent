import Foundation
@testable import Backup
@testable import KeyStore
import OnePassword
import Testing
@testable import Sync

private let me = "device-0001"
private let peer = "device-0002"
private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private let later = Date(timeIntervalSince1970: 1_800_000_600)

private func fingerprint(_ name: String) -> String { "SHA256:" + name }

private func key(_ name: String, hosts: [String] = [], tag: String = "tag-1") -> BackupKey {
    BackupKey(name: name, fingerprint: fingerprint(name), comment: name + "@example", hosts: hosts, privateKey: "private-" + name, changeTag: tag)
}

private func keyWithoutPrivateKey(_ name: String) -> BackupKey {
    BackupKey(name: name, fingerprint: fingerprint(name), comment: "", hosts: [], privateKey: nil, changeTag: "tag-1")
}

private func enclaveKey(_ name: String, hosts: [String] = []) -> BackupSecureEnclaveKey {
    BackupSecureEnclaveKey(name: name, publicKey: "ecdsa-sha2-nistp256 public-" + name, hosts: hosts)
}

private func sources(
    shared: [BackupKey] = [], read: BackupRead = .completeFull, local: [BackupKey] = [], secureEnclave: [BackupSecureEnclaveKey] = [],
    store: [String] = [], devices: Set<String> = [me, peer], unreadable: [UnreadableRecord] = []
) -> BackupSources {
    BackupSources(
        shared: shared, read: read, local: local, secureEnclave: secureEnclave, secureEnclaveTag: "enclave-1", deviceID: me, deviceName: "mac-a",
        devices: devices, unreadable: unreadable, storeFingerprints: Set(local.map(\.fingerprint)).union(store.map(fingerprint))
    )
}

private func vaultItem(_ content: ItemContent, id: String, updatedAt: Date = epoch) -> Item {
    Item(
        id: id, title: content.title, category: content.category, vaultID: "vault", fields: content.fields, sections: content.sections,
        notes: content.notes, tags: content.tags, version: 1, updatedAt: updatedAt
    )
}

/// The item the backup writes for `key`, as the vault stores it.
private func keyItem(_ key: BackupKey, scope: String = BackupFormat.shared, id: String, updatedAt: Date = epoch) throws -> Item {
    vaultItem(try #require(BackupDesiredItem(key: key, scope: scope)).content, id: id, updatedAt: updatedAt)
}

private func listItem(_ keys: [BackupSecureEnclaveKey], device: String, name: String, id: String) -> Item {
    vaultItem(BackupDesiredItem(secureEnclave: keys, device: device, deviceName: name, changeTag: "enclave-1").content, id: id)
}

/// An item of the user's, which no run changes.
private func foreignItem(id: String = "foreign", tags: [String] = []) -> Item {
    Item(id: id, title: "Bank", category: .login, vaultID: "vault", fields: [], sections: [], notes: "", tags: tags, version: 1, updatedAt: epoch)
}

private func overview(_ item: Item, state: ItemState = .active) -> ItemOverview {
    ItemOverview(id: item.id, title: item.title, category: item.category, vaultID: item.vaultID, tags: item.tags, updatedAt: item.updatedAt, state: state)
}

/// Plans a run, and plans again with the full items that the first plan lists to fetch.
private func plan(
    _ sources: BackupSources, vault: [Item], archived: [Item] = [], removed: BackupRemoved = .delete, cache: [String: BackupCacheEntry] = [:]
) -> BackupPlan {
    let overviews = vault.map { overview($0) } + archived.map { overview($0, state: .archived) }
    let first = BackupPlanner.plan(sources: sources, overviews: overviews, items: [], cache: cache, removed: removed)
    let ids = Set(first.fetch.flatMap { $0 })
    guard !ids.isEmpty else { return first }
    return BackupPlanner.plan(sources: sources, overviews: overviews, items: vault.filter { ids.contains($0.id) }, cache: cache, removed: removed)
}

private func ownerOfKey(_ name: String, scope: String = BackupFormat.shared) -> BackupOwner {
    BackupOwner(slot: .key(fingerprint: fingerprint(name), scope: scope), name: name)
}

// MARK: New, changed, removed and foreign items

@Test func aKeyWithNoItemGetsAnSSHKeyItem() throws {
    let result = plan(sources(shared: [key("work", hosts: ["*.example.com", "git"])]), vault: [])
    let item = try #require(result.create.first?.first)
    #expect(result.create.count == 1 && result.create[0].count == 1)
    #expect(item.slot == .key(fingerprint: fingerprint("work"), scope: BackupFormat.shared))
    #expect(item.content.category == .sshKey)
    #expect(item.content.title == "work")
    #expect(item.content.tags == ["signd"])
    let fields = Dictionary(uniqueKeysWithValues: item.content.fields.map { ($0.title, $0.value) })
    #expect(fields["private key"] == "private-work")
    #expect(fields["hosts"] == "*.example.com git")
    #expect(fields["comment"] == "work@example")
    #expect(fields["kind"] == "key" && fields["scope"] == "shared" && fields["name"] == "work")
    #expect(fields["fingerprint"] == fingerprint("work"))
    #expect(result.put.isEmpty && result.delete.isEmpty && result.archive.isEmpty && result.keep.isEmpty)
    // What the plan creates reads back as signd's item.
    #expect(BackupOwner(item: vaultItem(item.content, id: "new")) == ownerOfKey("work"))
}

@Test func newItemsAreCreatedInBatchesOfAHundred() {
    let keys = (0..<250).map { key(String(format: "key-%03d", $0)) }
    let result = plan(sources(shared: keys), vault: [])
    #expect(result.create.map(\.count) == [100, 100, 50])
}

@Test func aChangedKeyIsPutOnItsItem() throws {
    let before = try keyItem(key("work", hosts: ["old"]), id: "item-work")
    let result = plan(sources(shared: [key("work", hosts: ["new"], tag: "tag-2")]), vault: [before])
    #expect(result.create.isEmpty && result.delete.isEmpty)
    #expect(result.put.map(\.itemID) == ["item-work"])
    let fields = Dictionary(uniqueKeysWithValues: try #require(result.put.first).desired.content.fields.map { ($0.title, $0.value) })
    #expect(fields["hosts"] == "new")
}

@Test func aRenamedKeyKeepsItsItem() throws {
    let item = try keyItem(key("old-name"), id: "item-a")
    var renamed = key("old-name")
    renamed.name = "new-name"
    let result = plan(sources(shared: [renamed]), vault: [item])
    #expect(result.create.isEmpty && result.delete.isEmpty)
    #expect(result.put.map(\.itemID) == ["item-a"])
    #expect(result.put.first?.desired.content.title == "new-name")
}

@Test func anItemThatHasWhatItShouldIsLeftAlone() throws {
    var item = try keyItem(key("work"), id: "item-work")
    // 1Password adds fields of its own to an SSH Key item.
    item = Item(
        id: item.id, title: item.title, category: item.category, vaultID: item.vaultID,
        fields: item.fields + [Item.Field(id: "fingerprint-added", title: "key type", type: .text, value: "ed25519")],
        sections: item.sections, notes: item.notes, tags: item.tags, version: 2, updatedAt: item.updatedAt
    )
    let result = plan(sources(shared: [key("work")]), vault: [item])
    #expect(result.isIdle)
}

@Test(arguments: BackupRemoved.allCases)
func aRemovedKeysItemFollowsBackupRemoved(removed: BackupRemoved) throws {
    let gone = try keyItem(key("gone"), id: "item-gone")
    let kept = try keyItem(key("kept"), id: "item-kept")
    let result = plan(sources(shared: [key("kept")]), vault: [gone, kept], removed: removed)
    #expect(result.create.isEmpty && result.put.isEmpty)
    switch removed {
    case .delete:
        #expect(result.delete == [["item-gone"]])
        #expect(result.archive.isEmpty && result.keep.isEmpty)
    case .archive:
        #expect(result.archive == ["item-gone"])
        #expect(result.delete.isEmpty && result.keep.isEmpty)
    case .keep:
        #expect(result.keep == ["item-gone"])
        #expect(result.delete.isEmpty && result.archive.isEmpty)
        #expect(result.isIdle)
    }
}

@Test func removalsAreDeletedInBatchesOfFifty() throws {
    let items = try (0..<120).map { try keyItem(key(String(format: "key-%03d", $0)), id: String(format: "item-%03d", $0)) }
    let result = plan(sources(), vault: items)
    #expect(result.delete.map(\.count) == [50, 50, 20])
}

@Test func anItemOfTheUsersIsNeverChangedOrRemoved() throws {
    let gone = try keyItem(key("gone"), id: "item-gone")
    let untagged = foreignItem(id: "untagged")
    let otherTag = foreignItem(id: "other-tag", tags: ["work"])
    let overviews = [gone, untagged, otherTag].map { overview($0) }
    let first = BackupPlanner.plan(sources: sources(), overviews: overviews, items: [], cache: [:], removed: .delete)
    // An item without the tag is never read.
    #expect(first.fetch == [["item-gone"]])
    let result = plan(sources(), vault: [gone, untagged, otherTag])
    #expect(result.delete == [["item-gone"]])
    #expect(result.put.isEmpty && result.create.isEmpty && result.archive.isEmpty)
    #expect(result.cache.isEmpty)
}

@Test func anItemWithTheKeysFingerprintButNoTagIsNotTheKeysItem() throws {
    let lookalike = foreignItem(id: "lookalike")
    let result = plan(sources(shared: [key("work")]), vault: [lookalike])
    #expect(result.create.count == 1)
    #expect(result.put.isEmpty && result.delete.isEmpty)
}

enum MalformedItem: CaseIterable, Sendable {
    case noSection
    case unknownKind
    case scopeIsNotADevice
    case fingerprintWithoutPrefix
    case keyWithoutName
    case listForShared
    case sectionNotNamedSignd

    /// A tagged item that well-formed would be a removed key's item or a vanished Mac's list.
    var item: Item {
        func field(_ title: String, _ value: String) -> Item.Field {
            Item.Field(id: title, title: title, type: .text, value: value, sectionID: "s")
        }
        let section = Item.Section(id: "s", title: "signd")
        let keyFields = [field("kind", "key"), field("scope", "shared"), field("fingerprint", fingerprint("gone")), field("name", "gone")]
        func make(_ fields: [Item.Field], sections: [Item.Section]) -> Item {
            Item(id: "malformed", title: "x", category: .secureNote, vaultID: "vault", fields: fields, sections: sections, notes: "", tags: ["signd"], version: 1, updatedAt: epoch)
        }
        switch self {
        case .noSection: return make([], sections: [])
        case .unknownKind: return make([field("kind", "login"), field("scope", "shared")], sections: [section])
        case .scopeIsNotADevice: return make([field("kind", "key"), field("scope", "everyone"), field("fingerprint", fingerprint("gone")), field("name", "gone")], sections: [section])
        case .fingerprintWithoutPrefix: return make([field("kind", "key"), field("scope", "shared"), field("fingerprint", "gone"), field("name", "gone")], sections: [section])
        case .keyWithoutName: return make([field("kind", "key"), field("scope", "shared"), field("fingerprint", fingerprint("gone"))], sections: [section])
        case .listForShared: return make([field("kind", "secure-enclave-list"), field("scope", "shared")], sections: [section])
        case .sectionNotNamedSignd: return make(keyFields, sections: [Item.Section(id: "s", title: "other")])
        }
    }
}

@Test(arguments: MalformedItem.allCases)
func aTaggedItemThatIsNotWellFormedIsNeverChangedOrRemoved(malformed: MalformedItem) {
    let item = malformed.item
    #expect(BackupOwner(item: item) == nil)
    let result = plan(sources(devices: []), vault: [item])
    #expect(result.isIdle)
    #expect(result.keep.isEmpty)
    // The cache shows the item is not signd's, so the next run does not read it again.
    #expect(result.cache == [item.id: BackupCacheEntry(id: item.id, updatedAt: epoch, owner: nil, sourceTag: nil)])
}

@Test func anArchivedItemIsNotPlannedOrRead() throws {
    let archived = try keyItem(key("gone"), id: "item-archived")
    let first = BackupPlanner.plan(sources: sources(shared: [key("work")]), overviews: [overview(archived, state: .archived)], items: [], cache: [:], removed: .delete)
    #expect(first.fetch.isEmpty)
    #expect(first.create.count == 1)
    #expect(first.delete.isEmpty && first.archive.isEmpty && first.cache.isEmpty)
}

@Test func aKeyWithNoReadablePrivateKeyGetsNoItemAndKeepsItsOld() throws {
    let existing = try keyItem(key("work"), id: "item-work")
    let result = plan(sources(shared: [keyWithoutPrivateKey("work"), keyWithoutPrivateKey("new")]), vault: [existing])
    #expect(result.unavailable == [fingerprint("new"), fingerprint("work")])
    #expect(result.isIdle)
}

// MARK: Local keys and Secure Enclave lists

@Test func aLocalKeyGetsAnItemScopedToThisMac() throws {
    let result = plan(sources(local: [key("laptop-only")]), vault: [])
    let item = try #require(result.create.first?.first)
    #expect(item.slot == .key(fingerprint: fingerprint("laptop-only"), scope: me))
    #expect(BackupOwner(item: vaultItem(item.content, id: "new")) == ownerOfKey("laptop-only", scope: me))
}

@Test func noMacPlansAnotherMacsLocalItems() throws {
    let theirs = try keyItem(key("theirs"), scope: peer, id: "item-theirs")
    // Their key is not in this Mac's store, and this Mac's read is complete.
    let result = plan(sources(shared: [key("work")]), vault: [theirs])
    #expect(result.delete.isEmpty && result.archive.isEmpty && result.put.isEmpty)
    #expect(result.create.count == 1)
    #expect(result.cache["item-theirs"]?.owner == ownerOfKey("theirs", scope: peer))
}

@Test func aLocalKeyThatLeftTheStoreLosesItsItemOnThisMacOnly() throws {
    let mine = try keyItem(key("mine"), scope: me, id: "item-mine")
    #expect(plan(sources(), vault: [mine]).delete == [["item-mine"]])
    // The key is still in the store, now shared: its item stays.
    #expect(plan(sources(store: ["mine"]), vault: [mine]).isIdle)
}

@Test func aSharedKeyAndALocalKeyWithOneFingerprintAreTwoItems() throws {
    let result = plan(sources(shared: [key("work")], local: [key("work")]), vault: [])
    #expect(result.create.first?.map(\.slot.scope) == [BackupFormat.shared, me])
}

@Test func eachMacPutsItsOwnSecureEnclaveList() throws {
    let keys = [enclaveKey("yubikey-like", hosts: ["git"]), enclaveKey("a-first")]
    let result = plan(sources(secureEnclave: keys), vault: [])
    let item = try #require(result.create.first?.first)
    #expect(item.slot == .list(device: me))
    #expect(item.content.category == .secureNote)
    #expect(item.content.title == "signd Secure Enclave keys (mac-a)")
    #expect(item.content.notes == "a-first\necdsa-sha2-nistp256 public-a-first\nhosts: \n\nyubikey-like\necdsa-sha2-nistp256 public-yubikey-like\nhosts: git")
    #expect(BackupOwner(item: vaultItem(item.content, id: "new")) == BackupOwner(slot: .list(device: me), name: nil))

    // A change puts the list, and the other Mac's list is left alone.
    let mine = listItem([enclaveKey("a-first")], device: me, name: "mac-a", id: "list-mine")
    let theirs = listItem([enclaveKey("other")], device: peer, name: "mac-b", id: "list-theirs")
    let changed = plan(sources(secureEnclave: keys), vault: [mine, theirs])
    #expect(changed.put.map(\.itemID) == ["list-mine"])
    #expect(changed.create.isEmpty && changed.delete.isEmpty)
}

@Test func aMacWithNoSecureEnclaveKeysWritesNoListButKeepsItsOldOneCurrent() {
    #expect(plan(sources(), vault: []).isIdle)
    let old = listItem([enclaveKey("gone")], device: me, name: "mac-a", id: "list-mine")
    let result = plan(sources(devices: []), vault: [old])
    #expect(result.put.map(\.itemID) == ["list-mine"])
    #expect(result.delete.isEmpty && result.archive.isEmpty)
}

@Test func aSecureEnclaveListIsRemovedOnlyWhenItsMacsDeviceRecordIsGone() {
    let theirs = listItem([enclaveKey("other")], device: peer, name: "mac-b", id: "list-theirs")
    #expect(plan(sources(devices: [me, peer]), vault: [theirs]).isIdle)
    #expect(plan(sources(devices: [me]), vault: [theirs]).delete == [["list-theirs"]])
    #expect(plan(sources(devices: [me]), vault: [theirs], removed: .archive).archive == ["list-theirs"])
    // The record exists but could not be read.
    let unreadable = [UnreadableRecord(type: .device, name: peer)]
    #expect(plan(sources(devices: [me], unreadable: unreadable), vault: [theirs]).isIdle)
    // A read that did not complete decides nothing.
    #expect(plan(sources(read: .incomplete(reason: "x"), devices: [me]), vault: [theirs]).isIdle)
}

@Test func aMacNeverRemovesItsOwnSecureEnclaveList() {
    let mine = listItem([enclaveKey("a")], device: me, name: "mac-a", id: "list-mine")
    let result = plan(sources(secureEnclave: [enclaveKey("a")], devices: []), vault: [mine])
    #expect(result.isIdle)
}

// MARK: Reads that decide no removal

@Test func aFailedOrPartialReadRemovesNothingAndSaysWhy() throws {
    let gone = try keyItem(key("gone"), id: "item-gone")
    let theirsList = listItem([enclaveKey("other")], device: peer, name: "mac-b", id: "list-theirs")
    let mine = try keyItem(key("mine"), scope: me, id: "item-mine")
    for removed in BackupRemoved.allCases {
        let result = plan(
            sources(shared: [key("new")], read: .incomplete(reason: "the fetch stopped before its last page"), devices: []),
            vault: [gone, theirsList, mine], removed: removed
        )
        #expect(result.delete.isEmpty && result.archive.isEmpty && result.keep.isEmpty)
        #expect(result.skippedRemovals == "the fetch stopped before its last page")
        // The keys the read did list are still written.
        #expect(result.create.count == 1)
    }
}

@Test func aCompletedReadHasNoReasonToSkipRemovals() {
    #expect(plan(sources(), vault: []).skippedRemovals == nil)
}

@Test func aCompletedEmptyReadRemovesTheLastSharedKeysItem() throws {
    let last = try keyItem(key("last"), id: "item-last")
    #expect(plan(sources(shared: []), vault: [last]).delete == [["item-last"]])
    #expect(plan(sources(shared: []), vault: [last], removed: .archive).archive == ["item-last"])
}

@Test func aKeyInThisMacsStoreIsNeverRemoved() throws {
    let last = try keyItem(key("last"), id: "item-last")
    let result = plan(sources(shared: [], store: ["last"]), vault: [last])
    #expect(result.isIdle)
    #expect(result.cache["item-last"]?.owner == ownerOfKey("last"))
}

@Test func anUnreadableKeyRecordKeepsEverySharedItem() throws {
    let unread = try keyItem(key("unread"), id: "item-unread")
    let gone = try keyItem(key("gone"), id: "item-gone")
    // The item's name need not be the unreadable record's name, so no shared item is removed.
    let mine = try keyItem(key("mine"), scope: me, id: "item-mine")
    for removed in BackupRemoved.allCases {
        let result = plan(sources(unreadable: [UnreadableRecord(type: .key, name: "key-unread")]), vault: [unread, gone, mine], removed: removed)
        #expect(!result.delete.joined().contains("item-unread") && !result.delete.joined().contains("item-gone"))
        #expect(!result.archive.contains("item-unread") && !result.archive.contains("item-gone"))
        #expect(!result.keep.contains("item-unread") && !result.keep.contains("item-gone"))
    }
    // The items of this Mac's own keys are not shared, and still go.
    let result = plan(sources(unreadable: [UnreadableRecord(type: .key, name: "key-unread")]), vault: [unread, gone, mine])
    #expect(result.delete == [["item-mine"]])
}

// MARK: Duplicates

@Test func aDuplicateUpdatesTheOldestCopyAndLeavesTheOthers() throws {
    let oldest = try keyItem(key("work", hosts: ["old"]), id: "copy-oldest", updatedAt: epoch)
    let newest = try keyItem(key("work", hosts: ["old"]), id: "copy-newest", updatedAt: later)
    let result = plan(sources(shared: [key("work", hosts: ["new"])]), vault: [newest, oldest])
    #expect(result.put.map(\.itemID) == ["copy-oldest"])
    #expect(result.create.isEmpty && result.delete.isEmpty)
    #expect(result.cache["copy-newest"]?.owner == ownerOfKey("work"))
    // The cache records the copy the run writes to.
    #expect(result.cache["copy-newest"]?.target == "copy-oldest")

    // The run puts the oldest copy, which then has the newest `updatedAt`.
    let moved = Date(timeIntervalSince1970: 1_800_001_200)
    let written = try keyItem(key("work", hosts: ["new"]), id: "copy-oldest", updatedAt: moved)
    var recorded = result.cache
    recorded["copy-oldest"] = BackupCacheEntry(id: "copy-oldest", updatedAt: moved, owner: ownerOfKey("work"), sourceTag: "tag-1", target: "copy-oldest")
    let second = plan(sources(shared: [key("work", hosts: ["new"])]), vault: [newest, written], cache: recorded)
    #expect(second.isIdle)
    #expect(second.cache["copy-oldest"]?.target == "copy-oldest" && second.cache["copy-newest"]?.target == "copy-oldest")

    // The source changes again: the run keeps writing to the same copy, though the other is now the oldest.
    let third = plan(sources(shared: [key("work", hosts: ["newer"], tag: "tag-2")]), vault: [newest, written], cache: second.cache)
    #expect(third.put.map(\.itemID) == ["copy-oldest"])
    #expect(third.create.isEmpty && third.delete.isEmpty)

    // A target that no longer exists is replaced by the oldest copy left.
    let fourth = plan(sources(shared: [key("work", hosts: ["newer"], tag: "tag-2")]), vault: [newest], cache: second.cache)
    #expect(fourth.put.map(\.itemID) == ["copy-newest"])
}

@Test func aDuplicateThatIsCurrentNeedsNoWrite() throws {
    let first = try keyItem(key("work"), id: "copy-1", updatedAt: epoch)
    let second = try keyItem(key("work"), id: "copy-2", updatedAt: later)
    #expect(plan(sources(shared: [key("work")]), vault: [first, second]).isIdle)
}

@Test func aSlotWithAnyCurrentCopyIsNotWritten() throws {
    let stale = try keyItem(key("work", hosts: ["old"]), id: "copy-stale", updatedAt: epoch)
    let current = try keyItem(key("work", hosts: ["new"]), id: "copy-current", updatedAt: later)
    let wanted = sources(shared: [key("work", hosts: ["new"])])
    #expect(plan(wanted, vault: [stale, current]).isIdle)

    // A copy the cache shows current counts too, and is not read.
    let cache = ["copy-current": BackupCacheEntry(id: "copy-current", updatedAt: later, owner: ownerOfKey("work"), sourceTag: "tag-1")]
    let overviews = [overview(stale), overview(current)]
    let result = BackupPlanner.plan(sources: wanted, overviews: overviews, items: [stale], cache: cache, removed: .delete)
    #expect(result.fetch.isEmpty && result.isIdle)
}

@Test func removingAKeyRemovesEveryCopy() throws {
    let first = try keyItem(key("gone"), id: "copy-1", updatedAt: epoch)
    let second = try keyItem(key("gone"), id: "copy-2", updatedAt: later)
    #expect(plan(sources(), vault: [second, first]).delete == [["copy-1", "copy-2"]])
    #expect(plan(sources(), vault: [second, first], removed: .archive).archive == ["copy-1", "copy-2"])
}

// MARK: Items that could not be read

@Test func anItemWhoseReadFailedIsLeftAloneAndNothingIsCreated() throws {
    let stale = try keyItem(key("work", hosts: ["old"]), id: "item-work")
    let gone = try keyItem(key("gone"), id: "item-gone")
    let broken = try keyItem(key("broken"), id: "item-broken")
    let overviews = [stale, gone, broken].map { overview($0) }
    let wanted = sources(shared: [key("work", hosts: ["new"], tag: "tag-2"), key("new")])

    let first = BackupPlanner.plan(sources: wanted, overviews: overviews, items: [], cache: [:], removed: .delete)
    #expect(first.fetch == [["item-work", "item-gone", "item-broken"]])

    let result = BackupPlanner.plan(sources: wanted, overviews: overviews, items: [stale, gone], unread: ["item-broken"], cache: [:], removed: .delete)
    #expect(result.fetch.isEmpty)
    #expect(result.unread == ["item-broken"])
    #expect(result.create.isEmpty)
    #expect(result.put.map(\.itemID) == ["item-work"])
    #expect(result.delete == [["item-gone"]])
    #expect(result.cache["item-broken"] == nil)
}

@Test func aPlanThatAsksForReadsKeepsTheCacheItKnows() throws {
    let current = try keyItem(key("current"), id: "item-current")
    let added = try keyItem(key("added"), id: "item-added")
    let entry = BackupCacheEntry(id: "item-current", updatedAt: epoch, owner: ownerOfKey("current"), sourceTag: "tag-1")
    let result = BackupPlanner.plan(
        sources: sources(shared: [key("current"), key("added")]), overviews: [overview(current), overview(added)], items: [],
        cache: ["item-current": entry], removed: .delete
    )
    #expect(result.fetch == [["item-added"]])
    #expect(result.cache == ["item-current": entry])
    // A target the cache recorded is kept.
    let recorded = BackupCacheEntry(id: "item-current", updatedAt: epoch, owner: ownerOfKey("current"), sourceTag: "tag-1", target: "item-other")
    let again = BackupPlanner.plan(
        sources: sources(shared: [key("current"), key("added")]), overviews: [overview(current), overview(added)], items: [],
        cache: ["item-current": recorded], removed: .delete
    )
    #expect(again.cache == ["item-current": recorded])
    #expect(result.create.isEmpty && result.put.isEmpty && result.delete.isEmpty)
}

@Test func aPlanWithNoUnreadItemsListsNone() throws {
    let item = try keyItem(key("work"), id: "item-work")
    #expect(plan(sources(shared: [key("work")]), vault: [item]).unread.isEmpty)
}

// MARK: The cache

@Test func aCurrentCacheMakesOnlyTheListCall() throws {
    let item = try keyItem(key("work"), id: "item-work")
    let listed = [overview(item), overview(foreignItem())]
    let wanted = sources(shared: [key("work")])

    let first = BackupPlanner.plan(sources: wanted, overviews: listed, items: [], cache: [:], removed: .delete)
    #expect(first.fetch == [["item-work"]])
    #expect(first.create.isEmpty && first.put.isEmpty && first.delete.isEmpty)

    let second = BackupPlanner.plan(sources: wanted, overviews: listed, items: [item], cache: [:], removed: .delete)
    #expect(second.isIdle)
    let entry = BackupCacheEntry(id: "item-work", updatedAt: epoch, owner: ownerOfKey("work"), sourceTag: "tag-1")
    #expect(second.cache == ["item-work": entry])

    let third = BackupPlanner.plan(sources: wanted, overviews: listed, items: [], cache: second.cache, removed: .delete)
    #expect(third.fetch.isEmpty)
    #expect(third.isIdle)
    #expect(third.cache == second.cache)
}

@Test func theCacheHoldsNoSecret() throws {
    let item = try keyItem(key("work"), id: "item-work")
    let result = plan(sources(shared: [key("work")]), vault: [item])
    let json = String(decoding: try JSONEncoder().encode(result.cache), as: UTF8.self)
    #expect(!json.contains("private-work"))
}

@Test func onlyNewItemsAndItemsThatMovedAreRead() throws {
    let current = try keyItem(key("current"), id: "item-current")
    let added = try keyItem(key("added"), id: "item-added")
    let cache = [
        "item-current": BackupCacheEntry(id: "item-current", updatedAt: epoch, owner: ownerOfKey("current"), sourceTag: "tag-1"),
        "item-moved": BackupCacheEntry(id: "item-moved", updatedAt: epoch, owner: ownerOfKey("moved"), sourceTag: "tag-1"),
    ]
    let movedLater = try keyItem(key("moved"), id: "item-moved", updatedAt: later)
    let listed = [overview(current), overview(movedLater), overview(added)]
    let result = BackupPlanner.plan(sources: sources(shared: [key("current"), key("moved"), key("added")]), overviews: listed, items: [], cache: cache, removed: .delete)
    #expect(result.fetch == [["item-moved", "item-added"]])
}

@Test func itemsToReadGoInBatchesOfFifty() throws {
    let items = try (0..<120).map { try keyItem(key(String(format: "key-%03d", $0)), id: String(format: "item-%03d", $0)) }
    let result = BackupPlanner.plan(sources: sources(), overviews: items.map { overview($0) }, items: [], cache: [:], removed: .delete)
    #expect(result.fetch.map(\.count) == [50, 50, 20])
}

@Test func aChangedSourceWithACurrentCacheIsPutWithoutReadingTheItem() throws {
    let item = try keyItem(key("work"), id: "item-work")
    let cache = ["item-work": BackupCacheEntry(id: "item-work", updatedAt: epoch, owner: ownerOfKey("work"), sourceTag: "tag-1")]
    let result = BackupPlanner.plan(sources: sources(shared: [key("work", hosts: ["new"], tag: "tag-2")]), overviews: [overview(item)], items: [], cache: cache, removed: .delete)
    #expect(result.fetch.isEmpty)
    #expect(result.put.map(\.itemID) == ["item-work"])
    #expect(result.cache.isEmpty)
}

@Test func aCurrentCacheStillRemovesAKeyThatIsGone() throws {
    let item = try keyItem(key("gone"), id: "item-gone")
    let cache = ["item-gone": BackupCacheEntry(id: "item-gone", updatedAt: epoch, owner: ownerOfKey("gone"), sourceTag: "tag-1")]
    let result = BackupPlanner.plan(sources: sources(), overviews: [overview(item)], items: [], cache: cache, removed: .delete)
    #expect(result.fetch.isEmpty)
    #expect(result.delete == [["item-gone"]])
}

// MARK: The setting

@Test func backupRemovedHasTheChoicesOfTheSetting() {
    #expect(Settings.Key.backupRemoved.choices == BackupRemoved.allCases.map(\.rawValue))
    #expect(Settings.Key.backupRemoved.defaultValue == BackupRemoved.delete.rawValue)
}
