import Foundation

/// What `signd status` and `signd backup status` show of the backup.
/// It contains no secret.
public struct BackupStatus: Codable, Sendable, Equatable {
    /// Whether a token is stored; nil when this answer cannot tell, as when the agent does not answer.
    public var isOn: Bool?
    public var vault: String
    public var lastRun: Date?
    public var lastSuccess: Date?
    public var lastOutcome: BackupOutcome?
    public var lastError: String?
    /// When the next run is due; nil while the backup is off.
    /// A run that is overdue is due at `now`.
    public var nextRun: Date?

    public init(isOn: Bool?, vault: String, state: BackupState, schedule: BackupSchedule, now: Date = Date()) {
        self.isOn = isOn
        self.vault = vault
        lastRun = state.lastRun
        lastSuccess = state.lastSuccess
        lastOutcome = state.lastOutcome
        lastError = state.lastError
        nextRun = isOn == false ? nil : max(schedule.nextRun(lastChange: state.lastChange, lastRun: state.lastRun), now)
    }
}
