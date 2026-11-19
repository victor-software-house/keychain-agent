import Foundation
import os

private let log = Logger(subsystem: "com.victor-software-house.signd", category: "updater")

/// One check of the updater, from the settings to the restart of the agents, by design decisions 3 to 5.
///
/// A check makes no request while `updates` is off.
/// Otherwise it reads the latest release and stops unless the tag is newer than the installed version.
/// It stages the download, verifies the unpacked app, swaps it in, and restarts the agents.
/// A check that fails deletes the staging directory and records why.
public struct UpdateRun: Sendable {
    public struct Dependencies: Sendable {
        public var settings: @Sendable () -> UpdateSettings
        public var feed: ReleaseFeed
        public var staging: Staging
        /// The installed app.
        public var app: URL
        /// The team identifier of the running code, which an update must be signed by.
        public var team: @Sendable () throws -> String
        public var agents: AgentRestart
        public var now: @Sendable () -> Date

        public init(
            settings: @escaping @Sendable () -> UpdateSettings = { UpdateSettings() }, feed: ReleaseFeed = ReleaseFeed(), staging: Staging = Staging(),
            app: URL = URL(filePath: "/Applications/Signd.app", directoryHint: .isDirectory),
            team: @escaping @Sendable () throws -> String = { try AppBundle.runningTeam() }, agents: AgentRestart = AgentRestart.live,
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.settings = settings
            self.feed = feed
            self.staging = staging
            self.app = app
            self.team = team
            self.agents = agents
            self.now = now
        }
    }

    private let dependencies: Dependencies

    public init(_ dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
    }

    /// Runs one check.
    /// It runs on the global executor, so the download, the unpacking and the signature check block no actor.
    @concurrent public func perform() async -> UpdateState {
        var state = UpdateState()
        state.lastCheck = dependencies.now()
        guard dependencies.settings().isEnabled else {
            state.outcome = .off
            return state
        }
        do {
            try await update(&state)
        } catch {
            state.outcome = .failed
            state.error = String(describing: error)
        }
        if let message = state.error { log.error("check \(state.outcome?.rawValue ?? "unknown", privacy: .public): \(message, privacy: .public)") }
        return state
    }

    private func update(_ state: inout UpdateState) async throws {
        let installed = AppBundle(url: dependencies.app)
        guard let current = installed.version else { throw UpdateError("cannot read the version of \(dependencies.app.path)") }
        state.installed = current
        let release = try await dependencies.feed.latest()
        state.latest = release.version
        guard release.isNewer(than: current) else {
            state.outcome = .upToDate
            return
        }
        let team = try dependencies.team()
        let directory = try dependencies.staging.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let zip = try await dependencies.feed.download(release, to: directory)
        try dependencies.staging.unpack(zip, into: directory)
        let new = AppBundle(url: directory.appending(path: "Signd.app", directoryHint: .isDirectory))
        try dependencies.staging.seal(new.url)
        try new.verify(team: team)
        try new.requireVersion(release.version)
        try dependencies.staging.check(new.url)
        let users = dependencies.agents.users(running: installed.executable.path)
        try installed.swapContents(with: new)
        state.previous = current
        state.installed = release.version
        state.outcome = .installed
        do {
            try dependencies.agents.restart(users)
        } catch {
            state.error = "updated signd to \(release.version), but \(error)"
        }
    }
}
