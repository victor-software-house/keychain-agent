import AgentProtocol
import Darwin
import Foundation

/// One client: reads framed requests until the client closes, and answers each.
struct Connection {
    let fd: Int32
    let labels: [String]

    /// The keys, looked up on the first request that needs them, then kept for this connection.
    private var keys: [KeychainKey]?

    init(fd: Int32, labels: [String]) {
        self.fd = fd
        self.labels = labels
    }

    mutating func serve() {
        defer { close(fd) }
        while let header = readExactly(4) {
            guard let length = Frame.length(header: header), let body = readExactly(length) else { return }
            let message = Frame.encode(reply(to: Request(body: body)).body)
            guard writeAll(message) else { return }
        }
    }

    private mutating func reply(to request: Request) -> Response {
        switch request {
        case .identities:
            return .identities(loadedKeys().map(\.identity))
        case let .sign(keyBlob, data, flags):
            guard let key = loadedKeys().first(where: { $0.identity.blob == keyBlob }) else { return .failure }
            let algorithm = SignatureAlgorithm(flags: flags)
            do throws(SignError) {
                return .signature(algorithm: algorithm, bytes: try Keychain.sign(data, with: key, algorithm: algorithm))
            } catch {
                logError(error.description)
                return .failure
            }
        case .unsupported, .malformed:
            return .failure
        }
    }

    private mutating func loadedKeys() -> [KeychainKey] {
        if let keys { return keys }
        var loaded: [KeychainKey] = []
        for label in labels {
            do throws(KeyLookupError) {
                loaded.append(try Keychain.key(labelled: label))
            } catch {
                logError(error.description)
            }
        }
        keys = loaded
        return loaded
    }

    private func readExactly(_ count: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = buffer.withUnsafeMutableBytes { bytes in
                read(fd, bytes.baseAddress.map { $0 + done }, count - done)
            }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return nil }
            done += n
        }
        return Data(buffer)
    }

    private func writeAll(_ data: Data) -> Bool {
        var done = 0
        while done < data.count {
            let n = data.withUnsafeBytes { bytes in
                write(fd, bytes.baseAddress.map { $0 + done }, data.count - done)
            }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return false }
            done += n
        }
        return true
    }
}
