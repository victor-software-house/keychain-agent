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
        let state: UpdateState
        switch Updater.requestCheck() {
        case let .answered(answer): state = answer
        case .timedOut: throw Failure(UpdaterProblem.current(timedOut: true))
        case .unreachable: throw Failure(UpdaterProblem.current(timedOut: false))
        }
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
            throw Failure("the updater returned no result")
        }
    }

    /// The line for a check that installed a version.
    /// Within 5 minutes of a check, the updater answers each request with that check's result.
    /// An install that finished before the request is no new install, so the line gives the time it finished.
    ///
    /// An updater older than the fields that record the replaced version and the time of the install sends neither.
    /// The line then gives only the new version, as a new install.
    static func installedLine(_ state: UpdateState, asked: Date) -> String {
        let version = state.installed ?? "the new version"
        let from = state.previous.map { " from \($0)" } ?? ""
        if let done = state.installedAt, done < asked {
            return "signd is up to date (\(version), updated\(from) at \(done.formatted(.iso8601)))"
        }
        return "updated signd\(from) to \(version) and restarted the agent"
    }
}

/// Why `signd update` cannot reach the updater, and the command that fixes it.
enum UpdaterProblem {
    static let label = "com.victor-software-house.signd.updater"
    static let plist = "/Library/LaunchDaemons/com.victor-software-house.signd.updater.plist"
    static let package = "https://github.com/victor-software-house/signd/releases/latest/download/signd.pkg"
    static let caskrooms = ["/opt/homebrew/Caskroom/signd", "/usr/local/Caskroom/signd"]

    /// The message for this Mac.
    /// It depends on whether the daemon's file is installed, whether launchd loaded it, whether Homebrew installed signd, and whether the request timed out.
    static func message(hasPlist: Bool, isLoaded: Bool, isCask: Bool, timedOut: Bool) -> String {
        guard hasPlist else {
            return isCask
                ? "the updater is not installed; reinstall signd with: brew reinstall --cask signd"
                : "the updater is not installed; reinstall signd from \(package)"
        }
        guard isLoaded else { return "the updater is installed but not loaded; load it with: sudo launchctl bootstrap system \(plist)" }
        let restart = "sudo launchctl kickstart -k system/\(label)"
        guard timedOut else { return "the updater did not reply; restart it with: \(restart)" }
        let minutes = Int(Updater.checkTimeout / 60)
        return "the updater did not reply within \(minutes) minutes; if signd status shows no newer check, restart it with: \(restart)"
    }

    static func current(timedOut: Bool) -> String {
        let files = FileManager.default
        return message(
            hasPlist: files.fileExists(atPath: plist), isLoaded: isLoaded(), isCask: caskrooms.contains { files.fileExists(atPath: $0) }, timedOut: timedOut
        )
    }

    /// Whether launchd lists the daemon; `launchctl print` needs no root for the system domain.
    private static func isLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = ["print", "system/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// The updater, which the launch daemon runs as root.
/// It answers requests on its Mach service and runs the check that is due after a random delay.
/// It exits once it has been idle for 60 seconds.
struct UpdaterDaemon: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "updater", abstract: "Run the updater as the launch daemon does.", shouldDisplay: false)

    func run() throws {
        guard geteuid() == 0 else { throw Failure("run the updater as root") }
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
