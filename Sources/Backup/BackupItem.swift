import Foundation
import OnePassword
import SSHWire
import Sync

extension ItemCategory {
    /// Whether an item of this category can hold `key`.
    ///
    /// 1Password's SSH Key item takes Ed25519 keys, and Rivest-Shamir-Adleman (RSA) keys that meet two rules.
    /// The key has 2048, 3072 or 4096 bits, and its exponent is at least 65537.
    /// See [Manage SSH keys](https://www.1password.dev/ssh/manage-keys).
    ///
    /// A Secure Note takes every key, and no other category takes any.
    func supports(_ key: PublicKey) -> Bool {
        switch self {
        case .sshKey:
            switch key {
            case .ed25519:
                return true
            case .ecdsa:
                return false
            case let .rsa(exponent, modulus):
                let significant = modulus.drop { $0 == 0 }
                guard let first = significant.first else { return false }
                let bits = (significant.count - 1) * 8 + (8 - first.leadingZeroBitCount)
                let large = exponent.drop { $0 == 0 }
                return [2048, 3072, 4096].contains(bits) && (large.count > 3 || large.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } >= 65537)
            }
        case .secureNote:
            return true
        default:
            return false
        }
    }
}

/// How the backup writes an item and how it reads one back.
public enum BackupFormat {
    /// The tag of every item the backup writes.
    public static let tag = "signd"
    /// The scope of a shared key's item.
    public static let shared = "shared"
    static let sectionID = "signd"
    static let sectionTitle = "signd"
    static let fingerprintPrefix = "SHA256:"
    /// The version of the item shape: the title, notes, tags and fields a run writes.
    /// Raise it when any of them changes, and every Mac then writes each item once.
    static let itemVersion = 1
    /// The categories of a key's item, from the one to prefer: a key gets the first that supports it.
    static let keyCategories: [ItemCategory] = [.sshKey, .secureNote]

    /// The change tag a run compares for an item: the source's tag and the item version.
    /// An item that shows the device name, such as the Secure Enclave list, adds it.
    static func changeTag(source: String, deviceName: String? = nil) -> String {
        [String(itemVersion), deviceName ?? "", source].joined(separator: "\u{1F}")
    }

    /// Whether `scope` names a device: the record name of a `Device` record.
    static func isDevice(_ scope: String) -> Bool {
        scope.hasPrefix(RecordType.device.prefix) && scope.count > RecordType.device.prefix.count
    }
}

/// Which item of the vault a key or a Secure Enclave list belongs in.
/// A second item with the same slot is a duplicate.
public struct BackupSlot: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case key
        case secureEnclaveList = "secure-enclave-list"
    }

    public var kind: Kind
    /// `BackupFormat.shared`, or a device identifier.
    public var scope: String
    /// The `SHA256:` fingerprint of a key; nil for a list.
    public var fingerprint: String?

    public init(kind: Kind, scope: String, fingerprint: String? = nil) {
        self.kind = kind
        self.scope = scope
        self.fingerprint = fingerprint
    }

    public static func key(fingerprint: String, scope: String) -> Self {
        Self(kind: .key, scope: scope, fingerprint: fingerprint)
    }

    public static func list(device: String) -> Self {
        Self(kind: .secureEnclaveList, scope: device)
    }
}

/// What a well-formed `signd` section shows: the slot of the item, and a key's name.
public struct BackupOwner: Codable, Sendable, Hashable {
    public var slot: BackupSlot
    /// The key's name; nil for a list.
    public var name: String?

    public init(slot: BackupSlot, name: String?) {
        self.slot = slot
        self.name = name
    }

    /// The owner of `item`, or nil when the item is not signd's: it has no tag, no section, or a malformed one.
    public init?(item: Item) {
        guard item.tags.contains(BackupFormat.tag), let section = item.sections.first(where: { $0.title == BackupFormat.sectionTitle }) else { return nil }
        var values: [String: String] = [:]
        for field in item.fields where field.sectionID == section.id && values[field.title] == nil {
            values[field.title] = field.value
        }
        guard let kind = values["kind"].flatMap(BackupSlot.Kind.init(rawValue:)), let scope = values["scope"] else { return nil }
        switch kind {
        case .key:
            guard scope == BackupFormat.shared || BackupFormat.isDevice(scope),
                let fingerprint = values["fingerprint"], fingerprint.hasPrefix(BackupFormat.fingerprintPrefix), fingerprint.count > BackupFormat.fingerprintPrefix.count,
                let name = values["name"], !name.isEmpty
            else { return nil }
            self.init(slot: .key(fingerprint: fingerprint, scope: scope), name: name)
        case .secureEnclaveList:
            guard BackupFormat.isDevice(scope) else { return nil }
            self.init(slot: .list(device: scope), name: nil)
        }
    }
}

/// A key the backup copies.
public struct BackupKey: Sendable, Equatable {
    public var name: String
    /// The public key, which decides whether the item is an SSH Key item or a Secure Note.
    public var publicKey: PublicKey
    public var comment: String
    public var hosts: [String]
    /// The private key as the item stores it.
    /// It is nil when this Mac cannot read it, and then no item is written for the key.
    public var privateKey: String?
    /// Changes when the source of the key changes: the `Key` record's change tag for a shared key.
    public var changeTag: String

    /// The `SHA256:` fingerprint.
    public var fingerprint: String { publicKey.fingerprint }

    public init(name: String, publicKey: PublicKey, comment: String, hosts: [String], privateKey: String?, changeTag: String) {
        self.name = name
        self.publicKey = publicKey
        self.comment = comment
        self.hosts = hosts
        self.privateKey = privateKey
        self.changeTag = changeTag
    }
}

/// A key's description, debug description and mirror leave out the private key.
extension BackupKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private var redacted: [Mirror.Child] {
        [("name", name), ("fingerprint", fingerprint), ("changeTag", changeTag), ("hasPrivateKey", privateKey != nil)]
    }

    public var description: String { describeRedacted("BackupKey", redacted) }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: redacted, displayStyle: .struct) }
}

/// A Secure Enclave key, which the backup lists and cannot copy.
public struct BackupSecureEnclaveKey: Sendable, Equatable {
    public var name: String
    /// The public key as an `authorized_keys` line.
    public var publicKey: String
    public var hosts: [String]

    public init(name: String, publicKey: String, hosts: [String]) {
        self.name = name
        self.publicKey = publicKey
        self.hosts = hosts
    }
}

/// The item the backup writes for one slot.
public struct BackupDesiredItem: Sendable, Equatable {
    public let slot: BackupSlot
    public let changeTag: String
    public let content: ItemContent

    /// The item of `key`: an SSH Key item when 1Password takes the key, and otherwise a Secure Note.
    /// It is nil when this Mac has no private key for it.
    init?(key: BackupKey, scope: String) {
        guard let privateKey = key.privateKey, let category = BackupFormat.keyCategories.first(where: { $0.supports(key.publicKey) }) else { return nil }
        slot = .key(fingerprint: key.fingerprint, scope: scope)
        changeTag = BackupFormat.changeTag(source: key.changeTag)
        // A Secure Note has no field that derives the public key, so it has one of its own.
        let keyFields =
            category == .sshKey
            ? [Item.Field(id: "private_key", title: "private key", type: .sshKey, value: privateKey)]
            : [
                Item.Field(id: "private_key", title: "private key", type: .concealed, value: privateKey),
                Item.Field(id: Self.publicKeyFieldID, title: "public key", type: .text, value: key.publicKey.openSSHLine(comment: key.comment)),
            ]
        content = ItemContent(
            category: category, title: key.name,
            fields: keyFields + [
                Item.Field(id: "hosts", title: "hosts", type: .text, value: key.hosts.joined(separator: " ")),
                Item.Field(id: "comment", title: "comment", type: .text, value: key.comment),
            ] + Self.sectionFields(kind: .key, scope: scope, fingerprint: key.fingerprint, name: key.name),
            sections: [Item.Section(id: BackupFormat.sectionID, title: BackupFormat.sectionTitle)],
            tags: [BackupFormat.tag]
        )
    }

    /// The Secure Note that lists the Secure Enclave keys of one Mac.
    init(secureEnclave keys: [BackupSecureEnclaveKey], device: String, deviceName: String, changeTag: String) {
        slot = .list(device: device)
        self.changeTag = BackupFormat.changeTag(source: changeTag, deviceName: deviceName)
        let notes = keys.sorted { $0.name < $1.name }
            .map { [$0.name, $0.publicKey, "hosts: " + $0.hosts.joined(separator: " ")].joined(separator: "\n") }
            .joined(separator: "\n\n")
        content = ItemContent(
            category: .secureNote, title: "signd Secure Enclave keys (\(deviceName))",
            fields: Self.sectionFields(kind: .secureEnclaveList, scope: device, fingerprint: nil, name: nil),
            sections: [Item.Section(id: BackupFormat.sectionID, title: BackupFormat.sectionTitle)],
            notes: notes, tags: [BackupFormat.tag]
        )
    }

    fileprivate var redacted: [Mirror.Child] {
        [
            ("slot", slot), ("changeTag", changeTag), ("category", content.category.rawValue), ("title", content.title),
            ("fieldTitles", content.fields.map(\.title)),
        ]
    }

    /// The id of the text field that shows a Secure Note's public key.
    private static let publicKeyFieldID = "public_key"

    private static func sectionFields(kind: BackupSlot.Kind, scope: String, fingerprint: String?, name: String?) -> [Item.Field] {
        let values: [(title: String, value: String?)] = [("kind", kind.rawValue), ("scope", scope), ("fingerprint", fingerprint), ("name", name)]
        return values.compactMap { entry in
            entry.value.map { Item.Field(id: entry.title, title: entry.title, type: .text, value: $0, sectionID: BackupFormat.sectionID) }
        }
    }

    /// Whether `item` already has this item's title, notes, tags and fields.
    /// Fields the item has beyond the wanted ones, such as those 1Password adds to an SSH Key item, do not count.
    /// An SSH key field matches by its public key, which 1Password derives from the private key and may write in another text form.
    ///
    /// A Secure Note's public key field matches by the fingerprint of its text.
    /// A note with no readable public key does not match.
    func matches(_ item: Item) -> Bool {
        guard item.title == content.title, Self.trimmed(item.notes) == Self.trimmed(content.notes), Set(item.tags) == Set(content.tags) else { return false }
        let existing = Self.index(item.fields, item.sections)
        return Self.index(content.fields, content.sections).allSatisfy { key, wanted in
            guard let found = existing[key] else { return wanted.value.isEmpty }
            guard found.type == wanted.type else { return false }
            if wanted.type == .sshKey || wanted.id == Self.publicKeyFieldID {
                let shown = wanted.type == .sshKey ? found.publicKey : found.value
                guard let expected = slot.fingerprint, let actual = Self.fingerprint(ofPublicKey: shown) else { return false }
                return actual == expected
            }
            return Self.trimmed(found.value) == Self.trimmed(wanted.value)
        }
    }

    /// The fingerprint of an `authorized_keys` line, or of a bare key blob in base64; nil when neither parses.
    private static func fingerprint(ofPublicKey line: String?) -> String? {
        guard let line else { return nil }
        return line.split(whereSeparator: \.isWhitespace)
            .compactMap { token in Data(base64Encoded: String(token)).flatMap { blob in PublicKey(blob: blob) } }
            .first?.fingerprint
    }

    private struct FieldKey: Hashable {
        let section: String?
        let title: String
    }

    private static func index(_ fields: [Item.Field], _ sections: [Item.Section]) -> [FieldKey: Item.Field] {
        let titles = Dictionary(sections.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var index: [FieldKey: Item.Field] = [:]
        for field in fields {
            let key = FieldKey(section: field.sectionID.flatMap { titles[$0] }, title: field.title)
            if index[key] == nil { index[key] = field }
        }
        return index
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// An item's description, debug description and mirror leave out the value of every field, which includes the private key.
extension BackupDesiredItem: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { describeRedacted("BackupDesiredItem", redacted) }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: redacted, displayStyle: .struct) }
}

func describeRedacted(_ type: String, _ children: [Mirror.Child]) -> String {
    type + "(" + children.map { "\($0.label ?? ""): \($0.value)" }.joined(separator: ", ") + ")"
}

/// What a Mac remembers about one tagged item of the vault.
/// It contains no secret.
/// Encode it with exact dates, as the default `JSONEncoder` does, and never with `.iso8601`.
/// A run compares `updatedAt` with the vault's for equality, and whole seconds would make every entry look stale.
public struct BackupCacheEntry: Codable, Sendable, Equatable {
    public var id: String
    public var updatedAt: Date
    /// Nil for a tagged item that is not signd's.
    public var owner: BackupOwner?
    /// The change tag of the source this Mac last wrote or found in the item; nil when unknown.
    public var sourceTag: String?
    /// For an item whose slot has duplicates: the identifier of the copy a run writes to.
    /// A run that puts an item records the item's own identifier here.
    public var target: String?

    public init(id: String, updatedAt: Date, owner: BackupOwner?, sourceTag: String?, target: String? = nil) {
        self.id = id
        self.updatedAt = updatedAt
        self.owner = owner
        self.sourceTag = sourceTag
        self.target = target
    }

    public init(item: Item, sourceTag: String?, target: String? = nil) {
        self.init(id: item.id, updatedAt: item.updatedAt, owner: BackupOwner(item: item), sourceTag: sourceTag, target: target)
    }
}
