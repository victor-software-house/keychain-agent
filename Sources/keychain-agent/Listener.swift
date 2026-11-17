import Darwin
import Foundation
import Synchronization

/// The listening sockets: the ones launchd made, or one at a path given on the command line.
enum Listener {
    /// Why the agent has no socket to serve.
    enum SetupError: Error, CustomStringConvertible {
        case notActivated(errno: Int32)
        case pathTooLong(String)
        case call(String, path: String, errno: Int32)

        var description: String {
            switch self {
            case let .notActivated(code):
                return "launchd passed no Listeners socket (\(String(cString: strerror(code)))); start the agent from its LaunchAgent, or give --socket PATH"
            case let .pathTooLong(path):
                return "socket path too long: \(path)"
            case let .call(name, path, code):
                return "\(name) \(path): \(String(cString: strerror(code)))"
            }
        }
    }

    /// The sockets of the plist's `Sockets` entry named `Listeners`.
    static func activated() throws(SetupError) -> [Int32] {
        // launch_activate_socket writes a malloc'd array of descriptors into this slot.
        let slot = UnsafeMutablePointer<UnsafeMutablePointer<Int32>>.allocate(capacity: 1)
        defer { slot.deallocate() }
        var count = 0
        let result = launch_activate_socket("Listeners", slot, &count)
        guard result == 0, count > 0 else { throw .notActivated(errno: result) }
        let fds = slot.pointee
        defer { free(fds) }
        return Array(UnsafeBufferPointer(start: fds, count: count))
    }

    /// A socket bound at `path`, readable and writable only by this user.
    static func bound(at path: String) throws(SetupError) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw .pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .call("socket", path: path, errno: errno) }
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw .call("bind", path: path, errno: errno) }
        guard chmod(path, 0o600) == 0 else { throw .call("chmod", path: path, errno: errno) }
        guard listen(fd, 16) == 0 else { throw .call("listen", path: path, errno: errno) }
        return fd
    }
}

/// Clients being served now; the agent exits when idle only while this is zero.
let activeConnections = Atomic<Int>(0)

/// Accepts clients on `listeners`, each on its own thread, and returns after
/// `idleSeconds` with no new client and none still being served.
func serve(_ listeners: [Int32], labels: [String], idleSeconds: Int32) {
    var polls = listeners.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
    while true {
        let ready = poll(&polls, nfds_t(polls.count), idleSeconds * 1000)
        if ready == 0 {
            if activeConnections.load(ordering: .acquiring) == 0 { return }
            continue
        }
        if ready < 0 {
            if errno == EINTR { continue }
            logError("poll: \(String(cString: strerror(errno)))")
            return
        }
        for entry in polls where entry.revents & Int16(POLLIN) != 0 {
            let client = accept(entry.fd, nil, nil)
            guard client >= 0 else { continue }
            activeConnections.add(1, ordering: .acquiringAndReleasing)
            Thread.detachNewThread {
                var connection = Connection(fd: client, labels: labels)
                connection.serve()
                activeConnections.subtract(1, ordering: .acquiringAndReleasing)
            }
        }
    }
}
