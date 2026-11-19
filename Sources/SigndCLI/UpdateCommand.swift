import ArgumentParser
import Darwin
import Foundation
import Sync
import Updates

struct UpdateNow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Check for a newer release now, install it, and report the result.")
    @OptionGroup var colorOption: ColorOption

    func run() throws {
        let out = colorOption.standardOutput
        let asked = Date()
        guard let state = Updater.requestCheck() else { throw Failure("the updater does not answer; install signd from its package") }
        switch state.outcome {
        case .upToDate?:
            print(out.success("signd is up to date (\(state.installed ?? "unknown version"))"))
        case .installed?:
            if let error = state.error { throw Failure(error) }
            print(out.success(Self.installedLine(state, asked: asked)))
        case .off?:
            print(out.warning("updates are off (\(UpdateSettings().enabledSource.rawValue))"))
        case .failed?:
            throw Failure(state.error ?? "the update failed")
        case nil:
            throw Failure("the updater answered with no result")
        }
    }

    /// The line for a check that installed a version.
    /// Within 5 minutes of a check, the updater answers each request with that check's result.
    /// A result from a check that began before the request is no new install, so the line gives the time of the install.
    static func installedLine(_ state: UpdateState, asked: Date) -> String {
        let version = state.installed ?? "the new version"
        if let at = state.lastCheck, at < asked.addingTimeInterval(-1) {
            return "signd is up to date (\(version)), installed at \(at.formatted(.iso8601))"
        }
        return "installed \(version); the agents restart on it"
    }
}

/// The updater, which the launch daemon runs as root.
/// It answers requests on its Mach service and runs the check that is due after a random delay.
/// It exits once it has been idle for 60 seconds.
struct UpdaterDaemon: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "updater", abstract: "Run the updater as the launch daemon does.", shouldDisplay: false)

    func run() throws {
        guard geteuid() == 0 else { throw Failure("the updater runs as root") }
        signal(SIGPIPE, SIG_IGN)
        let run = UpdateRun()
        let updater = Updater(run: { await run.perform() })
        let inFlight = InFlight()
        let listener = try updater.listen(counting: inFlight)
        Task.detached {
            let schedule = UpdateSchedule()
            if schedule.isDue(lastCheck: UpdateState.load().lastCheck, interval: UpdateSettings().intervalSeconds) {
                try? await Task.sleep(for: .seconds(schedule.delay()))
                _ = await updater.check()
            }
            // The process exits inside the lock that guards the count of requests in flight.
            // A request that arrives later waits on that lock and never starts work, and its client sends it again.
            while true {
                while !(await updater.isIdle(for: 60)) { try? await Task.sleep(for: .seconds(1)) }
                _ = inFlight.exitIfNoneInFlight { Darwin.exit(0) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        withExtendedLifetime(listener) { dispatchMain() }
    }
}

extension UpdateStatus {
    /// The lines `signd status` prints.
    var lines: [String] {
        var lines = [
            settings.isEnabled
                ? "updates  on, every \(settings.interval) (\(settings.intervalSource.rawValue))"
                : "updates  off (\(settings.enabledSource.rawValue))"
        ]
        if let at = state.lastCheck, let outcome = state.outcome {
            lines.append("last update check  \(at.formatted(.iso8601)) \(outcome.rawValue)\(state.error.map { ": \(Display.clean($0))" } ?? "")")
        }
        return lines
    }
}
