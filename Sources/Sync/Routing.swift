import Darwin
import Foundation
import KeyStore
import SSHWire

/// The SSH configuration signd writes for its keys' hosts, under `~/.ssh/signd/`.
public enum Routing {
    /// The keys that take part: those with hosts, in name order.
    static func routed(_ keys: [StoredKey]) -> [StoredKey] {
        keys.filter { !$0.hosts.isEmpty && $0.hosts.allSatisfy(StoredKey.isValidHost) }.sorted { $0.name < $1.name }
    }

    /// `path` as SSH reads it: under `home` as `~/…`, quoted when it holds a space.
    static func reference(_ path: String, home: String) -> String {
        let text = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        return text.contains(where: \.isWhitespace) ? "\"\(text)\"" : text
    }

    /// The text of `config`, one `Host` block per key.
    public static func config(_ keys: [StoredKey], socket: String, home: String) -> String {
        routed(keys).map { key in
            [
                "Host \(key.hosts.joined(separator: " "))",
                "  IdentityAgent \(reference(socket, home: home))",
                "  IdentityFile \(reference(home + "/.ssh/signd/\(key.name).pub", home: home))",
                "  IdentitiesOnly yes",
            ].joined(separator: "\n") + "\n"
        }
        .joined(separator: "\n")
    }

    /// Writes `~/.ssh/signd/config` and each routed key's public file, and deletes the public file of a key that is gone or has no hosts.
    /// Each file is replaced whole, so SSH never reads a half-written one.
    public static func write(_ keys: [StoredKey], socket: String, home: URL) throws {
        let directory = home.appendingPathComponent(".ssh/signd")
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        var wanted: Set<String> = ["config"]
        for key in routed(keys) {
            guard let line = key.publicKey?.openSSHLine(comment: key.displayComment) else { continue }
            let name = "\(key.name).pub"
            wanted.insert(name)
            try replace(Data((line + "\n").utf8), at: directory.appendingPathComponent(name), mode: 0o644)
        }
        try replace(Data(config(keys, socket: socket, home: home.path).utf8), at: directory.appendingPathComponent("config"), mode: 0o600)
        for name in try manager.contentsOfDirectory(atPath: directory.path) where name.hasSuffix(".pub") && !wanted.contains(name) {
            try manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Replaces a file unless it already holds `data`.
    private static func replace(_ data: Data, at url: URL, mode: mode_t) throws {
        if FileManager.default.contents(atPath: url.path) == data { return }
        try AtomicFile.write(data, to: url, mode: mode)
    }
}
