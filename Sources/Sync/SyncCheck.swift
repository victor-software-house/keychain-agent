import CryptoKit
import Foundation
import KeyStore
import os
import SSHEncoding

private let log = Logger(subsystem: "com.victor-software-house.signd", category: "sync")

/// Opens a stored wrapped key to its private key and comment, as `Wrapping.openStored` does with the Secure Enclave.
public typealias KeyOpener = @Sendable (StoredKey) throws(SignError) -> (PrivateKey, String)

/// Opens a sealed secret with this device's key-agreement key, as `Wrapping.openSecret` does with the Secure Enclave.
public typealias SecretOpener = @Sendable (SealedSecret, DeviceKey) throws -> Data

/// What a check or a command changed, by key name.
struct Changes: Sendable {
    var added: [String] = []
    var replaced: [String] = []
    var removed: [String] = []
    /// Keys this device sealed for other devices.
    var sealed: [String] = []
    /// The backup token this device stores changed, so a backup run is due.
    var backupTokenChanged = false

    var isEmpty: Bool { added.isEmpty && replaced.isEmpty && removed.isEmpty && !backupTokenChanged }
}

/// A request the agent refuses, with the reason the command prints.
struct SyncRefusal: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The work of design decisions 4 to 6, on the state of one device: a check, and the commands that change shared keys and devices.
struct SyncCheck {
    let cloud: any CloudStore
    let store: any KeyStorage
    let device: DeviceKey
    /// This device's name, a Mac's `LocalHostName` in lowercase.
    let deviceName: String
    let version: String
    let open: KeyOpener
    /// Where this device keeps the backup token.
    let tokens: any TokenStore
    let openSecret: SecretOpener

    /// This device's record name.
    var me: String { device.recordName }

    // MARK: The check

    /// Reads the changes since the state's tokens, brings the store in line, publishes this device's record and seals keys for new devices.
    func run(from old: SyncState, requests: inout Int, changes: inout Changes) async throws -> SyncState {
        var state = old
        if !state.isPrepared {
            try await cloud.prepare()
            requests += 1
            state.isPrepared = true
        }
        var full = state.databaseToken == nil
        var fetched: CloudChanges
        do {
            fetched = try await cloud.changes(database: state.databaseToken, zone: state.zoneToken)
        } catch where error.kind == .tokenExpired || error.kind == .zoneMissing {
            requests += 1
            if error.kind == .zoneMissing {
                // The zone and its records are gone, so the full fetch below finds no records.
                // This Mac's own keys stay as local keys first, as after a zone loss.
                // Only the keys other devices shared go.
                try removeShared(changes: &changes)
                try await cloud.prepare()
                requests += 1
            }
            full = true
            fetched = try await cloud.changes(database: nil, zone: nil)
        }
        requests += fetched.requests

        if let loss = fetched.zoneLoss {
            try removeShared(changes: &changes)
            // The zone's records are gone, so the backup login ended.
            try tokens.delete()
            state.forgetRecords()
            state.isStopped = loss == .deletedByUser
            return state
        }
        state.databaseToken = fetched.databaseToken
        if let token = fetched.zoneToken { state.zoneToken = token }
        var changed = fetched.changed
        var deleted = fetched.deleted
        var failed: [UnreadableRecord] = []
        // A record an earlier read could not return is read by name now.
        // A name that still fails stays listed, and one that is gone is a deletion.
        for record in state.unreadable ?? [] {
            requests += 1
            do {
                if let found = try await cloud.fetch(record.type, name: record.name) {
                    changed.append(found)
                } else {
                    deleted.append(record.name)
                    changed.removeAll { $0.name == record.name }
                }
            } catch where error.kind == .other {
                failed.append(record)
            }
        }
        let read = Set(changed.map(\.name)).union(deleted)
        var listed = failed.filter { !read.contains($0.name) }
        let listedNames = Set(listed.map(\.name))
        listed += fetched.unreadable.filter { !listedNames.contains($0.name) }
        state.unreadable = listed.isEmpty ? nil : listed.sorted { $0.name < $1.name }
        // A full read lists every record it can read, so a record it does not list is gone.
        // A record it could not read keeps its last known state.
        let held = Set(listed.map(\.name))
        if full {
            state.devices = state.devices.filter { held.contains($0.key) }
            state.keys = state.keys.filter { held.contains($0.key) }
            if !held.contains(BackupPayload.recordName) { state.backup = nil }
        }

        // A record deleted and made again in one batch comes back as changed, so deletions go first.
        var payloads: [String: KeyPayload] = [:]
        var unreadable: [String: SkippedKey] = [:]
        var backup: BackupPayload?
        var backupSeen = false
        var backupGone = false
        for name in deleted {
            state.devices[name] = nil
            state.keys[name] = nil
            if name == BackupPayload.recordName {
                state.backup = nil
                backupGone = true
            }
        }
        for record in changed {
            switch record.type {
            case .device:
                state.devices[record.name] = Self.deviceEntry(record)
            case .backup:
                guard record.name == BackupPayload.recordName else { break }
                backupSeen = true
                backupGone = false
                // A record this version cannot read keeps the token this Mac has, as a later version may read it.
                if let payload = try? Payload.decode(BackupPayload.self, from: record.payload) {
                    state.backup = BackupEntry(sealedFor: payload.sealed.keys.sorted())
                    backup = payload
                }
            case .lease:
                break
            case .key:
                do throws(PayloadError) {
                    let payload = try Payload.decode(KeyPayload.self, from: record.payload)
                    state.keys[record.name] = KeyEntry(name: payload.name, hosts: payload.hosts, publicKey: payload.publicKey, sealedFor: payload.sealed.keys.sorted())
                    payloads[record.name] = payload
                } catch {
                    // A record this version cannot read keeps the key it gave before, as a later version may read it.
                    state.keys[record.name] = nil
                    unreadable[record.name] = SkippedKey(
                        record: record.name, name: String(record.name.dropFirst(RecordType.key.prefix.count)), kind: .invalidRecord, reason: error.description
                    )
                }
            }
        }

        var keys = try store.list()
        let touched = Set(deleted).union(payloads.keys).union(unreadable.keys)
        var skipped = old.skipped.filter { !touched.contains($0.record) && (!full || state.keys[$0.record] != nil || $0.kind == .invalidRecord || held.contains($0.record)) }
        skipped += unreadable.values

        for name in deleted {
            if let local = keys.first(where: { $0.isShared && $0.recordName == name }) { try delete(local, keys: &keys, changes: &changes) }
        }
        if full {
            // A full fetch cannot tell a record deleted on another Mac from a zone made again while this Mac was away.
            // A missing record therefore never deletes this Mac's own key.
            // It stays as a local key, and only received keys go.
            let kept = Set(state.keys.keys).union(skipped.filter { $0.kind == .invalidRecord }.map(\.record)).union(held)
            for local in keys where local.isShared && !kept.contains(local.recordName ?? "") {
                try unshare(local, keys: &keys, changes: &changes)
            }
        }

        // A name that a local key had may be free now.
        // Its record did not change, so it is fetched.
        let freed = skipped.filter { skip in skip.kind == .nameTaken && !keys.contains { $0.name == skip.name } }
        for skip in freed {
            skipped.removeAll { $0 == skip }
            requests += 1
            guard let record = try await cloud.fetch(.key, name: skip.record) else {
                state.keys[skip.record] = nil
                continue
            }
            if let payload = try? Payload.decode(KeyPayload.self, from: record.payload) {
                payloads[skip.record] = payload
                state.keys[skip.record] = KeyEntry(name: payload.name, hosts: payload.hosts, publicKey: payload.publicKey, sealedFor: payload.sealed.keys.sorted())
            }
        }

        for (record, payload) in payloads.sorted(by: { $0.key < $1.key }) {
            if let skip = try place(record, payload, keys: &keys, changes: &changes) { skipped.append(skip) }
        }
        state.skipped = skipped.sorted { ($0.name, $0.record) < ($1.name, $1.record) }

        // A full read that did not list the `Backup` record, and could not read it either, means the login ended.
        if full && !backupSeen && !held.contains(BackupPayload.recordName) { backupGone = true }
        try receiveToken(backup, gone: backupGone, changes: &changes)

        try await publish(&state, requests: &requests)
        try await sealForNewMacs(&state, keys: keys, requests: &requests, changes: &changes)
        try await sealTokenForNewMacs(&state, requests: &requests)
        return state
    }

    /// Stores the token this device's sealed copy opens to, when it differs from the stored one, and reports the change.
    /// Deletes the stored token when the record is gone, or when the record has no copy for this device.
    /// The stored token is then older than the record's, as after a login made while this device was unknown.
    private func receiveToken(_ payload: BackupPayload?, gone: Bool, changes: inout Changes) throws {
        if gone { return try tokens.delete() }
        guard let payload else { return }
        guard let sealed = payload.sealed[me] else { return try tokens.delete() }
        var token: Data
        do {
            token = try openSecret(sealed, device)
        } catch {
            log.error("cannot open this Mac's copy of the backup token: \(String(describing: error), privacy: .public)")
            return
        }
        defer { token.resetBytes(in: 0..<token.count) }
        if try tokens.read() != token {
            try tokens.save(token)
            changes.backupTokenChanged = true
        }
    }

    static func deviceEntry(_ record: CloudRecord) -> DeviceEntry? {
        guard let payload = try? Payload.decode(DevicePayload.self, from: record.payload),
              record.name == DeviceKey.recordName(for: payload.publicKey),
              (try? P256.KeyAgreement.PublicKey(x963Representation: payload.publicKey)) != nil
        else { return nil }
        return DeviceEntry(name: Display.clean(payload.name), publicKey: payload.publicKey, system: record.system)
    }

    /// Stores the key a record gives this device, or says why it does not.
    private func place(_ record: String, _ payload: KeyPayload, keys: inout [StoredKey], changes: inout Changes) throws -> SkippedKey? {
        let existing = keys.first { $0.isShared && $0.recordName == record }
        let name = Display.clean(payload.name)
        func skip(_ kind: SkipKind, _ reason: String) throws -> SkippedKey {
            if let existing { try delete(existing, keys: &keys, changes: &changes) }
            return SkippedKey(record: record, name: name, kind: kind, reason: reason)
        }
        guard record == KeyPayload.recordName(for: payload.name), StoredKey.isValidName(payload.name), PublicKey(blob: payload.publicKey) != nil else {
            return try skip(.invalidRecord, "the record's name, key name and public key do not agree")
        }
        if let host = payload.hosts.first(where: { !StoredKey.isValidHost($0) }) {
            return try skip(.invalidHost, "the hosts hold \"\(Display.clean(host))\", which is not a host pattern")
        }
        guard let sealed = payload.sealed[me] else {
            return try skip(.waiting, "no other device has shared it with this Mac yet")
        }
        if keys.contains(where: { $0.name == payload.name && $0.recordName != record }) {
            return SkippedKey(record: record, name: name, kind: .nameTaken, reason: "a key on this Mac that is not shared has the name \(name)")
        }
        var key = StoredKey(
            name: payload.name, kind: .wrapped, publicBlob: payload.publicKey, comment: Display.clean(payload.comment), hosts: payload.hosts,
            // A key this Mac made keeps its source when its record changes, as when another device seals it for a new one.
            source: existing?.source ?? StoredKey.receivedSource, keyData: device.handle, wrapped: sealed, recordName: record
        )
        if let existing {
            key.created = existing.created
            if existing == key { return nil }
            try store.replace(key)
            keys.removeAll { $0.name == key.name }
            keys.append(key)
            changes.replaced.append(key.name)
        } else {
            try store.add(key)
            keys.append(key)
            changes.added.append(key.name)
        }
        return nil
    }

    private func delete(_ key: StoredKey, keys: inout [StoredKey], changes: inout Changes) throws {
        try store.delete(name: key.name)
        keys.removeAll { $0.name == key.name }
        changes.removed.append(key.name)
    }

    /// Deletes every shared key on this device, as a change of account or a deleted zone needs.
    /// Deletes each key another device shared with this one.
    ///
    /// A key this Mac made or imported stays as a key of this Mac only.
    /// Its sealed copy opens with this device's key.
    /// No other copy may be left once the iCloud data is gone.
    func removeShared(changes: inout Changes) throws {
        var keys = try store.list()
        for key in keys where key.isShared { try unshare(key, keys: &keys, changes: &changes) }
    }

    /// Takes a key out of sharing: deletes a key another device shared, and keeps one this Mac made or imported as a local key.
    private func unshare(_ key: StoredKey, keys: inout [StoredKey], changes: inout Changes) throws {
        guard !key.isReceived else { return try delete(key, keys: &keys, changes: &changes) }
        var own = key
        own.recordName = nil
        try store.replace(own)
        keys.removeAll { $0.name == own.name }
        keys.append(own)
        changes.replaced.append(own.name)
    }

    /// Saves this device's record when the zone has none for its key, or one with another name.
    private func publish(_ state: inout SyncState, requests: inout Int) async throws {
        let entry = state.devices[me]
        if let entry, entry.name == deviceName, entry.publicKey == device.publicKey { return }
        let payload = DevicePayload(name: deviceName, publicKey: device.publicKey, version: version)
        requests += 1
        do {
            let saved = try await cloud.save(CloudRecord(type: .device, name: me, payload: Payload.encode(payload), system: entry?.system))
            state.devices[me] = DeviceEntry(name: deviceName, publicKey: device.publicKey, system: saved.system)
        } catch where error.kind == .conflict {
            // Another signd process on this device saved it first; the next check reads it.
        }
    }

    /// Seals each shared key this device has to every device that has no copy, as design decision 5 requires.
    /// It never drops a copy.
    private func sealForNewMacs(_ state: inout SyncState, keys: [StoredKey], requests: inout Int, changes: inout Changes) async throws {
        for local in keys where local.isShared {
            guard let record = local.recordName, let entry = state.keys[record] else { continue }
            let missing = state.devices.keys.filter { !entry.sealedFor.contains($0) }.sorted()
            guard !missing.isEmpty else { continue }
            requests += 1
            guard let current = try await cloud.fetch(.key, name: record), var payload = try? Payload.decode(KeyPayload.self, from: current.payload) else { continue }
            var added = false
            for device in missing where payload.sealed[device] == nil {
                guard let recipient = state.devices[device].flatMap({ try? P256.KeyAgreement.PublicKey(x963Representation: $0.publicKey) }) else { continue }
                let opened: (PrivateKey, String)
                do {
                    opened = try open(local)
                } catch {
                    log.error("cannot open \(local.name, privacy: .public) to share it: \(String(describing: error), privacy: .public)")
                    break
                }
                payload.sealed[device] = try Wrapping.seal(opened.0, comment: opened.1, to: recipient)
                added = true
            }
            state.keys[record]?.sealedFor = payload.sealed.keys.sorted()
            guard added else { continue }
            requests += 1
            do {
                _ = try await cloud.save(CloudRecord(type: .key, name: record, payload: Payload.encode(payload), system: current.system))
                changes.sealed.append(local.name)
            } catch where error.kind == .conflict {
                // Another device sealed it first; the next check reads that record.
                state.keys[record]?.sealedFor = entry.sealedFor
            }
        }
    }

    /// Seals the token that this device's own copy in the `Backup` record opens to, to every device that has no copy.
    /// A device with no copy in the record seals nothing, as the token it stored may be an older login's.
    /// It never drops a copy.
    private func sealTokenForNewMacs(_ state: inout SyncState, requests: inout Int) async throws {
        guard let entry = state.backup, entry.sealedFor.contains(me) else { return }
        let missing = state.devices.keys.filter { !entry.sealedFor.contains($0) }.sorted()
        guard !missing.isEmpty else { return }
        requests += 1
        guard let current = try await cloud.fetch(.backup, name: BackupPayload.recordName),
              var payload = try? Payload.decode(BackupPayload.self, from: current.payload),
              let own = payload.sealed[me]
        else { return }
        var token: Data
        do {
            token = try openSecret(own, device)
        } catch {
            log.error("cannot open this Mac's copy of the backup token to share it: \(String(describing: error), privacy: .public)")
            return
        }
        defer { token.resetBytes(in: 0..<token.count) }
        var added = false
        for device in missing where payload.sealed[device] == nil {
            guard let recipient = state.devices[device].flatMap({ try? P256.KeyAgreement.PublicKey(x963Representation: $0.publicKey) }) else { continue }
            payload.sealed[device] = try Wrapping.seal(secret: token, to: recipient)
            added = true
        }
        state.backup?.sealedFor = payload.sealed.keys.sorted()
        guard added else { return }
        requests += 1
        do {
            _ = try await cloud.save(CloudRecord(type: .backup, name: BackupPayload.recordName, payload: Payload.encode(payload), system: current.system))
        } catch where error.kind == .conflict {
            // Another device sealed it first; the next check reads that record.
            state.backup?.sealedFor = entry.sealedFor
        }
    }

    // MARK: Commands

    /// Logs in to the backup: seals the token to every known device, saves the `Backup` record, and stores this device's copy.
    func logInToBackup(token: Data, vault: String, state: inout SyncState, requests: inout Int) async throws {
        try await publish(&state, requests: &requests)
        var devices = state.devices
        if devices[me] == nil { devices[me] = DeviceEntry(name: deviceName, publicKey: device.publicKey, system: nil) }
        var sealed: [String: SealedSecret] = [:]
        for (id, entry) in devices {
            guard let recipient = try? P256.KeyAgreement.PublicKey(x963Representation: entry.publicKey) else { continue }
            sealed[id] = try Wrapping.seal(secret: token, to: recipient)
        }
        requests += 1
        let existing = try await cloud.fetch(.backup, name: BackupPayload.recordName)
        let payload = BackupPayload(vault: vault, sealed: sealed)
        requests += 1
        do {
            _ = try await cloud.save(CloudRecord(type: .backup, name: BackupPayload.recordName, payload: Payload.encode(payload), system: existing?.system))
        } catch where error.kind == .conflict {
            throw SyncRefusal("another Mac changed the backup login at the same moment; run the command again")
        } catch where error.kind == .quota {
            throw SyncRefusal("your iCloud storage is full, so the backup login was not saved")
        }
        try tokens.save(token)
        state.backup = BackupEntry(sealedFor: sealed.keys.sorted())
    }

    /// Deletes the `Backup` record and this device's token; every other device deletes its token at its next check.
    func logOutOfBackup(state: inout SyncState, requests: inout Int) async throws {
        requests += 1
        try await cloud.delete(.backup, name: BackupPayload.recordName)
        try tokens.delete()
        state.backup = nil
    }

    /// Shares a key of this device: seals it to every known device, saves its record, and keeps this device's own copy in its place.
    func share(_ name: String, state: inout SyncState, requests: inout Int) async throws -> StoredKey {
        guard let local = try store.list().first(where: { $0.name == name }) else { throw SyncRefusal(StoreError.notFound(name).description) }
        guard !local.isShared else { throw SyncRefusal("\(name) is already shared") }
        guard local.kind == .wrapped else { throw SyncRefusal("\(name) is a Secure Enclave key, which cannot leave this Mac") }
        let record = KeyPayload.recordName(for: name)
        if state.keys[record] != nil || state.skipped.contains(where: { $0.record == record }) {
            throw SyncRefusal("a shared key named \(name) exists; delete this Mac's own \(name) to take the shared one, or pick another name")
        }
        try await publish(&state, requests: &requests)
        var devices = state.devices
        if devices[me] == nil { devices[me] = DeviceEntry(name: deviceName, publicKey: device.publicKey, system: nil) }
        let (privateKey, comment) = try open(local)
        var sealed: [String: WrappedKey] = [:]
        for (id, device) in devices {
            guard let recipient = try? P256.KeyAgreement.PublicKey(x963Representation: device.publicKey) else { continue }
            sealed[id] = try Wrapping.seal(privateKey, comment: comment, to: recipient)
        }
        let payload = KeyPayload(name: name, comment: local.comment, hosts: local.hosts, publicKey: local.publicBlob, sealed: sealed)
        requests += 1
        do {
            _ = try await cloud.save(CloudRecord(type: .key, name: record, payload: Payload.encode(payload)))
        } catch where error.kind == .conflict {
            throw SyncRefusal("a shared key named \(name) exists; delete this Mac's own \(name) to take the shared one, or pick another name")
        } catch where error.kind == .quota {
            throw SyncRefusal("your iCloud storage is full, so \(name) was not shared")
        }
        var shared = local
        shared.keyData = device.handle
        shared.wrapped = sealed[me]
        shared.recordName = record
        try store.replace(shared)
        state.keys[record] = KeyEntry(name: name, hosts: local.hosts, publicKey: local.publicBlob, sealedFor: sealed.keys.sorted())
        return shared
    }

    /// Deletes a shared key's record, then this device's copy; every other device deletes its copy at its next check.
    func deleteShared(_ name: String, state: inout SyncState, requests: inout Int, changes: inout Changes) async throws {
        var keys = try store.list()
        guard let local = keys.first(where: { $0.name == name }), local.isShared, let record = local.recordName else {
            throw SyncRefusal("\(name) is not a shared key")
        }
        requests += 1
        try await cloud.delete(.key, name: record)
        try delete(local, keys: &keys, changes: &changes)
        state.keys[record] = nil
    }

    /// Deletes a device's record and drops its copies from every key.
    func removeDevice(_ id: String, state: inout SyncState, requests: inout Int) async throws {
        guard id != me else { throw SyncRefusal("\(id) is this Mac, which would publish its record again at its next check") }
        guard id.hasPrefix(RecordType.device.prefix) else { throw SyncRefusal("no device has the id \(id); see signd device list") }
        let known = state.devices[id] != nil
        // The copies go first, so a failure leaves the Device record, and running the command again finishes the removal.
        // Each pass reads every Key record, so a run after one that stopped halfway still finds the copies left.
        let dropped = try await dropCopies(for: id, state: &state, requests: &requests)
        // The refusal comes before the delete, so an id this Mac has not seen yet keeps its record.
        // An example is a Mac that published since the last check.
        guard known || dropped > 0 else { throw SyncRefusal("no device has the id \(id); see signd device list") }
        requests += 1
        try await cloud.delete(.device, name: id)
        state.devices[id] = nil
        // A device whose check started before the delete may have sealed a key to the removed one again; this pass drops that copy.
        // Checks that start after it do not list the device, so they seal nothing more to it.
        _ = try await dropCopies(for: id, state: &state, requests: &requests)
    }

    /// Drops the copy sealed to `id` from every Key record and the `Backup` record, reading a record again when another device saved it first.
    private func dropCopies(for id: String, state: inout SyncState, requests: inout Int) async throws -> Int {
        var dropped = 0
        for record in state.keys.keys.sorted() {
            for attempt in 1 ... 3 {
                requests += 1
                guard let current = try await cloud.fetch(.key, name: record), var payload = try? Payload.decode(KeyPayload.self, from: current.payload),
                      payload.sealed[id] != nil
                else { break }
                payload.sealed[id] = nil
                requests += 1
                do {
                    _ = try await cloud.save(CloudRecord(type: .key, name: record, payload: Payload.encode(payload), system: current.system))
                } catch where error.kind == .conflict && attempt < 3 {
                    continue
                }
                state.keys[record]?.sealedFor = payload.sealed.keys.sorted()
                dropped += 1
                break
            }
        }
        if state.backup != nil { dropped += try await dropBackupCopy(for: id, state: &state, requests: &requests) }
        return dropped
    }

    /// Drops the copy sealed to `id` from the `Backup` record, reading it again when another device saved it first.
    private func dropBackupCopy(for id: String, state: inout SyncState, requests: inout Int) async throws -> Int {
        for attempt in 1 ... 3 {
            requests += 1
            guard let current = try await cloud.fetch(.backup, name: BackupPayload.recordName),
                  var payload = try? Payload.decode(BackupPayload.self, from: current.payload),
                  payload.sealed[id] != nil
            else { return 0 }
            payload.sealed[id] = nil
            requests += 1
            do {
                _ = try await cloud.save(CloudRecord(type: .backup, name: BackupPayload.recordName, payload: Payload.encode(payload), system: current.system))
            } catch where error.kind == .conflict && attempt < 3 {
                continue
            }
            state.backup?.sealedFor = payload.sealed.keys.sorted()
            return 1
        }
        return 0
    }
}
