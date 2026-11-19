import ArgumentParser
import Darwin
import Foundation
import Sync
import Updates

struct UpdateNow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Check for a newer release now, install it, and report the result.")

    func run() throws {
        guard let state = Updater.requestCheck() else { throw Failure("the updater does not answer; install signd from its package") }
        switch state.outcome {
        case .upToDate?:
            print("signd is up to date (\(state.installed ?? "unknown version"))")
        case .installed?:
            if let error = state.error { throw Failure(error) }
            print("installed \(state.installed ?? "the new version"); the agents restart on it")
        case .off?:
            print("updates are off (\(UpdateSettings().enabledSource.rawValue))")
        case .failed?:
            throw Failure(state.error ?? "the update failed")
        case nil:
            throw Failure("the updater answered with no result")
        }
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
        let listener = try updater.listen()
        Task.detached {
            let schedule = UpdateSchedule()
            if schedule.isDue(lastCheck: UpdateState.load().lastCheck, interval: UpdateSettings().intervalSeconds) {
                try? await Task.sleep(for: .seconds(schedule.delay()))
                _ = await updater.check()
            }
            // A request that arrives between the idle check and the exit would be killed with the process.
            // So the listener stops first, and the updater refuses new checks before the process exits.
            while true {
                while !(await updater.isIdle(for: 60)) { try? await Task.sleep(for: .seconds(1)) }
                listener.cancel()
                if await updater.shutdown(idleFor: 60) { Darwin.exit(0) }
            }
        }
        dispatchMain()
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
