import Foundation
import Sync

/// What the `lease-backup` record shows: the Mac that runs the backup, and when its claim ends.
struct LeasePayload: Codable, Sendable, Equatable {
    var format = 1
    var holder: String
    var expires: Date
}

/// The claim that keeps two Macs from running the backup at once, by design decision 5.
///
/// Every save is conditional on the record's change tag.
/// So two claims cannot both succeed, a renewal fails once another Mac took over, and a late clear never removes another Mac's claim.
/// Only the backup reads the record, so no key change or SSH request waits on it.
public struct BackupLease: Sendable {
    public static let recordName = RecordType.lease.prefix + "backup"
    /// How long a claim lasts, from the save that made or renewed it.
    public static let duration: TimeInterval = 600

    public enum Claim: Sendable, Equatable {
        case acquired
        /// Another Mac has an unexpired claim, or took the lease at the same moment.
        case held
    }

    private let cloud: any CloudStore
    private let holder: String
    private let now: @Sendable () -> Date
    /// The change tag the next save checks: the one the last save of this Mac returned.
    private var system: Data?

    public init(cloud: any CloudStore, holder: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.cloud = cloud
        self.holder = holder
        self.now = now
    }

    /// Takes the lease when none exists, when its claim has expired, or when it is this Mac's own.
    public mutating func claim() async throws(CloudError) -> Claim {
        let current = try await cloud.fetch(.lease, name: Self.recordName)
        if let current, let other = try? Payload.decode(LeasePayload.self, from: current.payload), other.holder != holder, other.expires > now() {
            return .held
        }
        do {
            system = try await save(expires: now().addingTimeInterval(Self.duration), over: current?.system)
            return .acquired
        } catch where error.kind == .conflict {
            return .held
        }
    }

    /// Extends the claim.
    /// It fails when another Mac saved the record since this Mac's last save, and the run stops.
    public mutating func renew() async throws(CloudError) {
        system = try await save(expires: now().addingTimeInterval(Self.duration), over: system)
    }

    /// Ends the claim with an expired one.
    /// A conflict means another Mac has the lease now.
    /// Any other failure leaves the claim to expire on its own.
    public mutating func clear() async {
        _ = try? await save(expires: .distantPast, over: system)
    }

    private func save(expires: Date, over system: Data?) async throws(CloudError) -> Data? {
        let payload = Payload.encode(LeasePayload(holder: holder, expires: expires))
        return try await cloud.save(CloudRecord(type: .lease, name: Self.recordName, payload: payload, system: system)).system
    }
}
