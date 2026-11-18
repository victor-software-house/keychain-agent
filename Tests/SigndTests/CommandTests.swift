import Foundation
@testable import KeyStore
import Testing
@testable import signd
@testable import Sync

@Test func theJSONReportCarriesTheLoginItemAndTheSSHInclude() throws {
    let sync = SyncStatus(state: SyncState(), settings: Settings(local: { _ in nil }))
    let report = Status.Report(version: "0.0.0", socket: "/s", agentAnswers: false, agent: nil, sync: sync, loginItem: .requiresApproval, sshInclude: true)
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
    #expect(object["loginItem"] as? String == "requiresApproval")
    #expect(object["sshInclude"] as? Bool == true)
}

@Test func logShowsTheLastHourAndStreamsWithFollow() {
    let predicate = ["--predicate", "subsystem == \"com.victor-software-house.signd\""]
    #expect(Service.Log.arguments(follow: false) == ["show", "--last", "1h"] + predicate)
    #expect(Service.Log.arguments(follow: true) == ["stream"] + predicate)
}
