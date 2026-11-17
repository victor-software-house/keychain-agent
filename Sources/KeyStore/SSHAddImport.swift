import AgentProtocol
import Darwin
import Dispatch
import Foundation
import SSHWire
import Synchronization

/// What the private agent socket has seen: the first key ssh-add added, and whether the import is over.
private final class Session: Sendable {
    private let key = Mutex<(PrivateKey, String)?>(nil)
    private let finished = Mutex(false)

    var captured: (PrivateKey, String)? { key.withLock { $0 } }
    var isFinished: Bool { finished.withLock { $0 } }

    func capture(_ privateKey: PrivateKey, _ comment: String) {
        key.withLock { if $0 == nil { $0 = (privateKey, comment) } }
    }

    func finish() { finished.withLock { $0 = true } }
}

extension KeyImport {
    /// Imports a passphrase-protected key file through the system `ssh-add`.
    ///
    /// ssh-add asks for the passphrase on this process's terminal or through `SSH_ASKPASS`, decrypts the file
    /// with OpenSSH's own code, and adds the key to a private agent socket that this function serves.
    /// The key reaches this process in memory only; the socket is the only file written, in a 0700 directory removed afterwards.
    /// An ssh-add comment that is only the file's path counts as no comment.
    public static func importWithSSHAdd(file: String) throws(ImportError) -> (PrivateKey, String) {
        var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("signd-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw .sshAdd("cannot make a private directory") }
        let directory = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let socketPath = directory + "/agent"
        let listener = try listen(at: socketPath)
        defer { close(listener) }

        let session = Session()
        let served = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            serve(listener, session)
            served.signal()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        process.arguments = [file.hasPrefix("-") ? "./" + file : file]
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_AUTH_SOCK"] = socketPath
        process.environment = environment
        do {
            try process.run()
        } catch {
            session.finish()
            served.wait()
            throw .sshAdd("cannot run /usr/bin/ssh-add: \(error)")
        }
        process.waitUntilExit()
        session.finish()
        served.wait()

        guard process.terminationStatus == 0 else { throw .sshAdd("exited with status \(process.terminationStatus)") }
        guard let added = session.captured else { throw .sshAdd("did not add a key") }
        try validate(added.0)
        return (added.0, added.1 == file ? "" : added.1)
    }

    private static func listen(at path: String) throws(ImportError) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .sshAdd("cannot make a socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw .sshAdd("the temporary directory's path is too long for a socket")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            close(fd)
            throw .sshAdd("cannot listen on a private socket")
        }
        return fd
    }

    /// Accepts connections until the import is over, answering only add and list requests.
    private static func serve(_ listener: Int32, _ session: Session) {
        while !session.isFinished {
            var events = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&events, 1, 100) > 0 else { continue }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { continue }
            answer(connection, session)
            close(connection)
        }
    }

    private static func answer(_ connection: Int32, _ session: Session) {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(connection, &uid, &gid) == 0, uid == getuid() else { return }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        while !session.isFinished {
            guard let header = read(connection, count: 4, session) else { return }
            let length = header.reduce(0) { $0 << 8 | Int($1) }
            guard length <= Frame.maximumLength, let body = read(connection, count: length, session) else { return }
            let reply: Response
            switch Request(body: body) {
            case let .add(key, comment, _):
                session.capture(key, comment)
                reply = .success
            case .identities:
                reply = .identities([])
            default:
                reply = .failure
            }
            var message = Data()
            message.appendString(reply.body)
            guard write(connection, message) else { return }
        }
    }

    private static func read(_ fd: Int32, count: Int, _ session: Session) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < count {
            let n = Darwin.read(fd, &buffer, min(buffer.count, count - data.count))
            if n > 0 {
                data.append(contentsOf: buffer[0..<n])
            } else if n < 0, errno == EAGAIN || errno == EINTR, !session.isFinished {
                continue
            } else {
                return nil
            }
        }
        return data
    }

    private static func write(_ fd: Int32, _ message: Data) -> Bool {
        var offset = 0
        while offset < message.count {
            let n = message.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            offset += n
        }
        return true
    }
}
