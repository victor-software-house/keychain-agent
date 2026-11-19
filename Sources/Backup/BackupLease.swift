import Foundation
import Sync

/// What the `lease-backup` record shows: the Mac that runs the backup, and when its claim ends.
struct LeasePayload: Codable, Sendable, Equatable {
    var format = 1
    var holder: String
    var expires: Date
}

/// The expiry that every format of the `lease-backup` payload carries.
private struct LeaseExpiry: Decodable {
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
    /// When the last claim or renewal of this Mac succeeded.
    private var renewed: Date?

    public init(cloud: any CloudStore, holder: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.cloud = cloud
        self.holder = holder
        self.now = now
    }

    /// Takes the lease when none exists, when its claim has expired, or when it is this Mac's own.
    public mutating func claim() async throws(CloudError) -> Claim {
        let current = try await cloud.fetch(.lease, name: Self.recordName)
        if let current, isHeldByAnother(current.payload) { return .held }
        do {
            let began = now()
            system = try await save(expires: began.addingTimeInterval(Self.duration), over: current?.system)
            renewed = began
            return .acquired
        } catch where error.kind == .conflict {
            return .held
        }
    }

    /// Extends the claim.
    /// It fails when another Mac saved the record since this Mac's last save, and the run stops.
    public mutating func renew() async throws(CloudError) {
        let began = now()
        system = try await save(expires: began.addingTimeInterval(Self.duration), over: system)
        renewed = began
    }

    /// Extends the claim once a third of its length has passed since the last claim or renewal, and otherwise does nothing.
    /// A run calls it before each 1Password call, so a slow call never leaves the claim to expire.
    public mutating func renewIfDue() async throws(CloudError) {
        guard let renewed, now().timeIntervalSince(renewed) >= Self.duration / 3 else { return }
        try await renew()
    }

    /// Ends the claim with an expired one.
    /// A conflict means another Mac has the lease now.
    /// Any other failure leaves the claim to expire on its own.
    public mutating func clear() async {
        _ = try? await save(expires: .distantPast, over: system)
    }

    /// Whether the record shows another Mac's claim that has not expired.
    /// A payload this version cannot read as its format still counts by its expiry, as a later version may have written it.
    /// Only a record with no readable expiry counts as free.
    private func isHeldByAnother(_ payload: Data) -> Bool {
        if let other = try? Payload.decode(LeasePayload.self, from: payload) { return other.holder != holder && other.expires > now() }
        guard let claim = try? JSONDecoder().decode(LeaseExpiry.self, from: payload) else { return false }
        return claim.expires > now()
    }

    private func save(expires: Date, over system: Data?) async throws(CloudError) -> Data? {
        let payload = Payload.encode(LeasePayload(holder: holder, expires: expires))
        return try await cloud.save(CloudRecord(type: .lease, name: Self.recordName, payload: payload, system: system)).system
    }
}
