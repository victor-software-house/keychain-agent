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

    private func callExtension(_ name: String, argument: String? = nil, timeout: Int = 5) -> Data? {
        var body = Data([MessageType.extension.rawValue])
        body.appendString(name)
        if let argument { body.appendString(Data(argument.utf8)) }
        return call(body, timeout: timeout)
    }

    /// The agent's status, or nil when no agent answers.
    func status() -> AgentStatus? {
        guard let reply = callExtension(PrivateExtension.status), reply.first == MessageType.extensionResponse.rawValue else { return nil }
        var reader = Reader(reply.dropFirst())
        guard reader.text() == PrivateExtension.status, let json = reader.string() else { return nil }
        return try? JSONDecoder().decode(AgentStatus.self, from: json)
    }

    /// Asks the agent to check iCloud now and returns the check's result, or nil when no agent answers.
    func sync() -> CheckSummary? {
        // A check waits for any share in flight and can retry, so it may take longer than a status call.
        decoded(PrivateExtension.sync, timeout: 120)
    }

    /// The agent's sync state, or nil when no agent answers.
    func syncState() -> SyncState? {
        decoded(PrivateExtension.syncState, timeout: 5)
    }

    /// Asks the agent to share a stored key, or nil when no agent answers.
    func share(_ key: String) -> SyncResult? {
        decoded(PrivateExtension.share, argument: key, timeout: 120)
    }

    /// Asks the agent to delete a shared key on every device, or nil when no agent answers.
    func deleteShared(_ key: String) -> SyncResult? {
        decoded(PrivateExtension.deleteShared, argument: key, timeout: 120)
    }

    /// Asks the agent to store the backup token on every Mac, or nil when no agent answers.
    func backupLogin(_ request: BackupLoginRequest) -> SyncResult? {
        guard let json = try? JSONEncoder().encode(request) else { return nil }
        return decoded(PrivateExtension.backupLogin, argument: String(decoding: json, as: UTF8.self), timeout: 120)
    }

    /// Asks the agent to delete the backup token on every Mac, or nil when no agent answers.
    func backupLogout() -> SyncResult? {
        decoded(PrivateExtension.backupLogout, timeout: 120)
    }

    /// The devices of the account, or nil when no agent answers.
    func devices() -> [DeviceSummary]? {
        decoded(PrivateExtension.devices, timeout: 5)
    }

    /// Asks the agent to remove a device, or nil when no agent answers.
    func removeDevice(_ id: String) -> SyncResult? {
        decoded(PrivateExtension.removeDevice, argument: id, timeout: 120)
    }

    private func decoded<Value: Decodable>(_ name: String, argument: String? = nil, timeout: Int) -> Value? {
        guard let reply = callExtension(name, argument: argument, timeout: timeout), reply.first == MessageType.extensionResponse.rawValue else { return nil }
        var reader = Reader(reply.dropFirst())
        guard reader.text() == name, let json = reader.string() else { return nil }
        return try? JSONDecoder().decode(Value.self, from: json)
    }

    /// Asks a running agent to read the stored keys again; does nothing when none runs.
    func reload() {
        _ = callExtension(PrivateExtension.reload)
    }
}
