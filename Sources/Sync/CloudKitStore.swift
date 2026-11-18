import CloudKit
import Foundation

/// signd's iCloud private database, through CloudKit.
///
/// Create it only with a container that the process's signature lists, as `CloudContainer.signed` reads it.
/// CloudKit stops a process that requests a container it is not entitled to.
public struct CloudKitStore: CloudStore {
    static let zoneName = "signd"
    static let subscriptionID = "signd-changes"
    /// Each request gets 10 seconds, and a request with its retries 30, so a check never hangs on a lost connection.
    static let requestTimeout: TimeInterval = 10
    static let resourceTimeout: TimeInterval = 30

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID

    public init(containerID: String) {
        container = CKContainer(identifier: containerID)
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    private static func configuration() -> CKOperation.Configuration {
        let configuration = CKOperation.Configuration()
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.qualityOfService = .utility
        return configuration
    }

    /// Runs `body` with the timeouts, and turns any error into a `CloudError`.
    private func run<Value: Sendable>(_ body: @escaping @Sendable (CKDatabase) async throws -> Value) async throws(CloudError) -> Value {
        do {
            return try await database.configuredWith(configuration: Self.configuration()) { database in
                try await body(database)
            }
        } catch {
            throw Self.map(error)
        }
    }

    public func account() async throws(CloudError) -> CloudAccount {
        do {
            switch try await container.accountStatus() {
            case .available:
                return .available(user: try await container.userRecordID().recordName)
            case .noAccount:
                return .unavailable("no iCloud account is signed in")
            case .restricted:
                return .unavailable("iCloud is restricted on this Mac")
            case .temporarilyUnavailable:
                return .unavailable("iCloud is temporarily unavailable; sign in again in System Settings")
            case .couldNotDetermine:
                return .unavailable("macOS could not tell whether an iCloud account is signed in")
            @unknown default:
                return .unavailable("macOS reported an iCloud account status signd does not know")
            }
        } catch {
            throw Self.map(error)
        }
    }

    public func prepare() async throws(CloudError) {
        let zoneID = zoneID
        try await run { database in
            let zones = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            _ = try zones.saveResults[zoneID]?.get()
            let subscription = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            // A badge makes CloudKit send the push at high priority; the agent shows no badge.
            info.shouldBadge = true
            subscription.notificationInfo = info
            let subscriptions = try await database.modifySubscriptions(saving: [subscription], deleting: [])
            _ = try subscriptions.saveResults[Self.subscriptionID]?.get()
        }
    }

    public func changes(database databaseToken: Data?, zone zoneToken: Data?) async throws(CloudError) -> CloudChanges {
        let zoneID = zoneID
        let start: CKServerChangeToken?
        let zoneStart: CKServerChangeToken?
        do {
            start = try databaseToken.map(Self.token)
            zoneStart = try zoneToken.map(Self.token)
        } catch {
            throw CloudError(.tokenExpired, "a stored change token cannot be read")
        }
        return try await run { database in
            var result = CloudChanges()
            var token = start
            var zoneChanged = false
            var more = true
            while more {
                let changes = try await database.databaseChanges(since: token)
                result.requests += 1
                if changes.modifications.contains(where: { $0.zoneID == zoneID }) { zoneChanged = true }
                if let deletion = changes.deletions.first(where: { $0.zoneID == zoneID }) {
                    result.zoneLoss = deletion.reason == .purged ? .deletedByUser : .deleted
                }
                token = changes.changeToken
                more = changes.moreComing
            }
            result.databaseToken = token.map(Self.archive)
            guard result.zoneLoss == nil, zoneChanged || zoneStart == nil else { return result }

            var zoneToken = zoneStart
            more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: zoneToken)
                result.requests += 1
                for (_, outcome) in changes.modificationResultsByID {
                    if case let .success(modification) = outcome, let record = Self.record(modification.record) {
                        result.changed.append(record)
                    }
                }
                result.deleted += changes.deletions.map(\.recordID.recordName)
                zoneToken = changes.changeToken
                more = changes.moreComing
            }
            result.zoneToken = zoneToken.map(Self.archive)
            return result
        }
    }

    public func fetch(_ type: RecordType, name: String) async throws(CloudError) -> CloudRecord? {
        let id = CKRecord.ID(recordName: name, zoneID: zoneID)
        do {
            return try await run { database in
                Self.record(try await database.record(for: id))
            }
        } catch where error.kind == .notFound {
            return nil
        }
    }

    public func save(_ record: CloudRecord) async throws(CloudError) -> CloudRecord {
        let ckRecord: CKRecord
        if let system = record.system {
            guard let restored = Self.restore(system) else { throw CloudError(.other, "the record's stored system fields cannot be read") }
            ckRecord = restored
        } else {
            ckRecord = CKRecord(recordType: record.type.rawValue, recordID: CKRecord.ID(recordName: record.name, zoneID: zoneID))
        }
        ckRecord.encryptedValues["payload"] = record.payload as NSData
        let id = ckRecord.recordID
        return try await run { database in
            let result = try await database.modifyRecords(saving: [ckRecord], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let saved = try result.saveResults[id]?.get(), let read = Self.record(saved) else {
                throw CloudError(.other, "CloudKit answered the save without the record")
            }
            return read
        }
    }

    public func delete(_ type: RecordType, name: String) async throws(CloudError) {
        let id = CKRecord.ID(recordName: name, zoneID: zoneID)
        do {
            try await run { database in
                let result = try await database.modifyRecords(saving: [], deleting: [id])
                _ = try result.deleteResults[id]?.get()
            }
        } catch where error.kind == .notFound {
            return
        }
    }

    // MARK: Conversions

    static func record(_ record: CKRecord) -> CloudRecord? {
        guard let type = RecordType(rawValue: record.recordType) else { return nil }
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        let payload = record.encryptedValues["payload"] as? Data ?? Data()
        return CloudRecord(type: type, name: record.recordID.recordName, payload: payload, system: coder.encodedData)
    }

    static func restore(_ system: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: system) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    static func archive(_ token: CKServerChangeToken) -> Data {
        (try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)) ?? Data()
    }

    static func token(_ data: Data) throws -> CKServerChangeToken {
        guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return token
    }

    /// The kind of a CloudKit error, with its retry-after time.
    static func map(_ error: any Error) -> CloudError {
        if let error = error as? CloudError { return error }
        guard let error = error as? CKError else {
            let ns = error as NSError
            return CloudError(ns.domain == NSURLErrorDomain ? .network : .other, ns.localizedDescription)
        }
        if error.code == .partialFailure, let first = error.partialErrorsByItemID?.values.first {
            return map(first)
        }
        let retryAfter = error.retryAfterSeconds
        let kind: CloudError.Kind = switch error.code {
        case .networkUnavailable, .networkFailure, .serverResponseLost: retryAfter == nil ? .network : .throttled
        case .serviceUnavailable, .requestRateLimited, .zoneBusy: .throttled
        case .notAuthenticated, .accountTemporarilyUnavailable, .managedAccountRestricted: .account
        case .changeTokenExpired: .tokenExpired
        case .zoneNotFound: .zoneMissing
        case .userDeletedZone: .zoneDeletedByUser
        case .serverRecordChanged: .conflict
        case .unknownItem: .notFound
        case .quotaExceeded: .quota
        default: .other
        }
        return CloudError(kind, error.localizedDescription, retryAfter: retryAfter)
    }
}

/// The iCloud container this process may use.
///
/// The App ID's iCloud settings call the container once.
/// The provisioning profile carries it into the signature, so the code contains no container name.
/// A fork with its own App ID and container needs no code change.
public enum CloudContainer {
    /// The one container the process's own signature lists, or nil in a build without the entitlement, such as one from source.
    public static var signed: String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil),
              let containers = value as? [String], containers.count == 1
        else { return nil }
        return containers[0]
    }
}
