import Foundation

/// Whether the device can use iCloud, and for which user.
public enum CloudAccount: Sendable, Equatable {
    /// `user` is the user record name, which changes when another Apple account signs in.
    case available(user: String)
    case unavailable(String)
}

/// How the `signd` zone was lost.
public enum ZoneLoss: Sendable, Equatable {
    /// Deleted by signd or reset with the account's encrypted data; signd makes it again.
    case deleted
    /// Deleted by the user in iCloud settings; signd waits for `signd sync`.
    case deletedByUser
}

/// The changes since two change tokens.
public struct CloudChanges: Sendable {
    public var changed: [CloudRecord] = []
    /// Record names.
    public var deleted: [String] = []
    public var databaseToken: Data?
    /// Nil when the zone was not read because it did not change.
    public var zoneToken: Data?
    public var zoneLoss: ZoneLoss?
    /// The names of records the read could not return.
    /// A read with any is incomplete, so a check that gets one changes nothing.
    public var unreadable: [String] = []
    public var requests = 0

    public init() {}
}

/// Why a CloudKit call failed, as signd acts on it.
public struct CloudError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// The network failed or a request timed out.
        case network
        /// CloudKit throttled signd; `retryAfter` is the wait CloudKit returned, when it returned one.
        case throttled
        /// The account is signed out or not available.
        case account
        case tokenExpired
        case zoneMissing
        case zoneDeletedByUser
        /// The record changed on the server since it was read.
        case conflict
        case notFound
        /// The user's iCloud storage is full.
        case quota
        case other
    }

    public var kind: Kind
    public var retryAfter: TimeInterval?
    public var message: String

    public init(_ kind: Kind, _ message: String, retryAfter: TimeInterval? = nil) {
        self.kind = kind
        self.message = message
        self.retryAfter = retryAfter
    }

    public var description: String { message }
}

/// The calls signd makes to its iCloud private database, so tests need no network and no entitlement.
public protocol CloudStore: Sendable {
    func account() async throws(CloudError) -> CloudAccount
    /// Saves the `signd` zone and the database subscription, which a second save leaves as they are.
    func prepare() async throws(CloudError)
    func changes(database: Data?, zone: Data?) async throws(CloudError) -> CloudChanges
    /// One record, or nil when there is none.
    func fetch(_ type: RecordType, name: String) async throws(CloudError) -> CloudRecord?
    /// Saves a new record, or a changed one against the change tag in its system fields, and returns it as saved.
    func save(_ record: CloudRecord) async throws(CloudError) -> CloudRecord
    /// Deletes a record; one that is already gone is no error.
    func delete(_ type: RecordType, name: String) async throws(CloudError)
}
