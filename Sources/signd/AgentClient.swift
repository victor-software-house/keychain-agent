import AgentProtocol
import AgentServer
import Darwin
import Foundation
import SSHWire
import Sync

/// The agent socket, `~/.ssh/signd.sock`.
let defaultSocketPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/signd.sock").path

/// A short-lived connection to the agent, for status and reload.
struct AgentClient {
    let path: String

    /// Sends one request body and returns the reply body, or nil when no agent answers within `timeout` seconds.
    func call(_ body: Data, timeout: Int = 5) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var limit = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        var message = Data()
        message.appendString(body)
        guard message.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == message.count,
              let header = read(fd, count: 4) else { return nil }
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        return read(fd, count: length)
    }

    private func read(_ fd: Int32, count: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < count {
            let n = Darwin.read(fd, &buffer, min(buffer.count, count - data.count))
            guard n > 0 else { return nil }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }

    private func callExtension(_ name: String, timeout: Int = 5) -> Data? {
        var body = Data([MessageType.extension.rawValue])
        body.appendString(name)
        return call(body, timeout: timeout)
    }

    /// The agent's status, or nil when no agent answers.
    func status() -> AgentStatus? {
        guard let reply = callExtension(PrivateExtension.status), reply.first == MessageType.extensionResponse.rawValue else { return nil }
        var reader = Reader(reply.dropFirst())
        guard reader.text() == PrivateExtension.status, let json = reader.string() else { return nil }
        return try? JSONDecoder().decode(AgentStatus.self, from: json)
    }

    /// Asks the agent to check 1Password now and returns the check's result, or nil when no agent answers.
    func sync() -> CheckSummary? {
        // A check makes several requests to 1Password, so it may take longer than a status call.
        decoded(PrivateExtension.sync, timeout: 300)
    }

    /// Asks the agent to sign out, and returns what it did, or nil when no agent that knows the request answers.
    func logout() -> LogoutResult? {
        decoded(PrivateExtension.logout, timeout: 60)
    }

    /// Tells the agent that a new token is stored, so it forgets the old state and starts syncing from the token.
    /// Returns whether an agent that knows the request answered; one that does not leaves the state to the caller.
    func login() -> Bool {
        callExtension(PrivateExtension.login)?.first == MessageType.success.rawValue
    }

    private func decoded<Value: Decodable>(_ name: String, timeout: Int) -> Value? {
        guard let reply = callExtension(name, timeout: timeout), reply.first == MessageType.extensionResponse.rawValue else { return nil }
        var reader = Reader(reply.dropFirst())
        guard reader.text() == name, let json = reader.string() else { return nil }
        return try? JSONDecoder().decode(Value.self, from: json)
    }

    /// Asks a running agent to read the stored keys again; does nothing when none runs.
    func reload() {
        _ = callExtension(PrivateExtension.reload)
    }
}
