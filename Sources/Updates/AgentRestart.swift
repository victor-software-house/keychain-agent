import Darwin
import Foundation

/// A process on the Mac: the executable it runs, its arguments, and its user.
public struct RunningProcess: Sendable, Equatable {
    public let path: String
    public let arguments: [String]
    public let uid: uid_t

    public init(path: String, arguments: [String], uid: uid_t) {
        self.path = path
        self.arguments = arguments
        self.uid = uid
    }

    /// Every process this one can read.
    public static func all() -> [RunningProcess] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride)))
        return pids.prefix(max(count, 0)).compactMap { RunningProcess(pid: $0) }
    }

    private init?(pid: pid_t) {
        guard pid > 0 else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN.
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard length > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        self.init(path: String(decoding: path.prefix(Int(length)), as: UTF8.self), arguments: Self.readArguments(of: pid), uid: info.pbi_uid)
    }

    /// The arguments of process `pid`, from `KERN_PROCARGS2`: the argument count, the executable path, then each argument and the environment.
    private static func readArguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let count = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        let strings = buffer.prefix(size).dropFirst(MemoryLayout<Int32>.size).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return Array(strings.dropFirst().prefix(max(count, 0)))
    }
}

/// Finds each user's running agent and restarts it on the new binary, by design decision 5.
/// The process list and the launcher are injected, so a test starts nothing.
public struct AgentRestart: Sendable {
    public let processes: @Sendable () -> [RunningProcess]
    /// Restarts the agent job of one user.
    public let kickstart: @Sendable (_ uid: uid_t) throws -> Void

    public init(processes: @escaping @Sendable () -> [RunningProcess], kickstart: @escaping @Sendable (_ uid: uid_t) throws -> Void) {
        self.processes = processes
        self.kickstart = kickstart
    }

    public static let live = AgentRestart(processes: { RunningProcess.all() }, kickstart: { try AgentRestart.launchctl($0) })

    /// The users whose `signd serve` runs from `executable`, each once.
    /// The updater reads them before the swap, since a process whose file was swapped away may not name it any more.
    public func users(running executable: String) -> [uid_t] {
        Set(processes().filter { $0.path == executable && $0.arguments.contains("serve") }.map(\.uid)).sorted()
    }

    /// Restarts the agent of each user, and throws after it tried every one when any failed.
    public func restart(_ users: [uid_t]) throws {
        var failures: [String] = []
        for uid in users {
            do { try kickstart(uid) } catch { failures.append("user \(uid): \(error)") }
        }
        guard failures.isEmpty else { throw UpdateError("cannot restart the agent of \(failures.joined(separator: "; "))") }
    }

    private static func launchctl(_ uid: uid_t) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(uid)/\(AppBundle.identifier)"]
        do { try process.run() } catch { throw UpdateError("cannot run launchctl: \(error)") }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("launchctl kickstart failed with status \(process.terminationStatus)") }
    }
}
