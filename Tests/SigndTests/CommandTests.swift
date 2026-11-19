import ArgumentParser
import Foundation
@testable import Backup
@testable import KeyStore
import Testing
@testable import SigndCLI
@testable import Sync
@testable import Updates

private let noUpdates = UpdateStatus(settings: UpdateSettings(managed: noPlist, machine: noPlist), state: UpdateState())

@Test func theJSONReportCarriesTheLoginItemAndTheSSHInclude() throws {
    let sync = SyncStatus(state: SyncState(), settings: Settings(local: { _ in nil }))
    let report = Status.Report(version: "0.0.0", socket: "/s", agentAnswers: false, agent: nil, sync: sync, backup: nil, update: noUpdates, loginItem: .requiresApproval, isSSHIncludeEnabled: true)
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
    #expect(object["loginItem"] as? String == "requiresApproval")
    #expect(object["sshInclude"] as? Bool == true)
}

@Test func theJSONReportCarriesTheBackupFields() throws {
    var state = BackupState()
    state.lastRun = at(0)
    state.lastSuccess = at(-86400)
    state.lastOutcome = .failed
    state.lastError = "boom"
    let sync = SyncStatus(state: SyncState(), settings: Settings(local: { _ in nil }))
    func backup(of status: BackupStatus) throws -> [String: Any] {
        let report = Status.Report(version: "0.0.0", socket: "/s", agentAnswers: true, agent: nil, sync: sync, backup: status, update: noUpdates, loginItem: .enabled, isSSHIncludeEnabled: true)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        return try #require(object["backup"] as? [String: Any])
    }

    let on = try backup(of: BackupStatus(isOn: true, vault: "signd", state: state, schedule: BackupSchedule(), now: at(10)))
    #expect(on["isOn"] as? Bool == true)
    #expect(on["vault"] as? String == "signd")
    #expect(on["lastOutcome"] as? String == "failed")
    #expect(on["lastError"] as? String == "boom")
    #expect(on["lastRun"] as? Double == at(0).timeIntervalSinceReferenceDate)
    #expect(on["lastSuccess"] as? Double == at(-86400).timeIntervalSinceReferenceDate)
    // With no key change waiting, the next run is a day after the last.
    #expect(on["nextRun"] as? Double == at(86400).timeIntervalSinceReferenceDate)

    let off = try backup(of: BackupStatus(isOn: false, vault: "signd", state: BackupState(), schedule: BackupSchedule(), now: at(10)))
    #expect(off["isOn"] as? Bool == false)
    #expect(off["nextRun"] == nil)
    // A Mac whose agent does not answer leaves the token unknown.
    let unknown = try backup(of: BackupStatus(isOn: nil, vault: "signd", state: BackupState(), schedule: BackupSchedule(), now: at(10)))
    #expect(unknown["isOn"] == nil)
    // A run that has never happened is due now.
    #expect(unknown["nextRun"] as? Double == at(10).timeIntervalSinceReferenceDate)
}

@Test func theJSONReportCarriesTheUpdateFields() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let machine = directory.appending(path: "machine.plist")
    try writePlist(["updates": false], to: machine)
    var state = UpdateState()
    state.lastCheck = at(0)
    state.installed = "0.0.13"
    state.latest = "0.0.14"
    state.outcome = .failed
    state.error = "boom"
    let update = UpdateStatus(settings: UpdateSettings(managed: noPlist, machine: machine), state: state)
    let sync = SyncStatus(state: SyncState(), settings: Settings(local: { _ in nil }))
    let report = Status.Report(
        version: "0.0.0", socket: "/s", agentAnswers: true, agent: nil, sync: sync, backup: nil, update: update, loginItem: .enabled, isSSHIncludeEnabled: true
    )
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
    let json = try #require(object["update"] as? [String: Any])
    let settings = try #require(json["settings"] as? [String: Any])
    #expect(settings["updates"] as? Bool == false)
    #expect(settings["updatesSource"] as? String == "machine")
    #expect(settings["interval"] as? String == "6h")
    #expect(settings["intervalSource"] as? String == "default")
    let last = try #require(json["state"] as? [String: Any])
    #expect(last["outcome"] as? String == "failed")
    #expect(last["error"] as? String == "boom")
    #expect(last["installed"] as? String == "0.0.13")
    #expect(last["latest"] as? String == "0.0.14")
    #expect(last["lastCheck"] as? Double == at(0).timeIntervalSinceReferenceDate)
    #expect(update.lines == ["updates  off (machine)", "last update check  \(at(0).formatted(.iso8601)) failed: boom"])
}

@Test func theUpdateLinesShowTheIntervalAndItsSource() {
    let settings = UpdateSettings(managed: noPlist, machine: noPlist)
    #expect(UpdateStatus(settings: settings, state: UpdateState()).lines == ["updates  on, every 6h (default)"])
}

@Test func serviceEnableTakesAtLoginFromTheHook() throws {
    #expect(try Service.Enable.parse([]).atLogin == false)
    #expect(try Service.Enable.parse(["--at-login"]).atLogin)
}

@Test func logShowsTheLastHourAndStreamsWithFollow() {
    let predicate = ["--predicate", "subsystem == \"com.victor-software-house.signd\""]
    #expect(Service.Log.arguments(follow: false) == ["show", "--last", "1h", "--info", "--debug"] + predicate)
    #expect(Service.Log.arguments(follow: true) == ["stream", "--level", "debug"] + predicate)
}
