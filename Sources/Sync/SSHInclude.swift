import Darwin
import Foundation

/// The `Include` line in `~/.ssh/config` that makes SSH read `~/.ssh/signd/config`.
public enum SSHInclude {
    public static let line = "Include ~/.ssh/signd/config"

    /// Whether `config` has a line that includes signd's file.
    /// A line counts when it comes before the first `Host` or `Match` line.
    /// Its keyword is `Include`, in any case.
    /// One of its arguments is `~/.ssh/signd/config`, the same path under `home`, or `signd/config`.
    public static func isPresent(in config: String, home: String) -> Bool {
        let accepted: Set<String> = ["~/.ssh/signd/config", home + "/.ssh/signd/config", "signd/config"]
        for text in config.split(whereSeparator: \.isNewline) {
            let line = text.drop(while: { $0 == " " || $0 == "\t" })
            let end = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) ?? line.endIndex
            switch line[..<end].lowercased() {
            case "host", "match": return false
            case "include": if arguments(line[end...]).contains(where: accepted.contains) { return true }
            case _: break
            }
        }
        return false
    }

    /// `config` with the line and a blank line at its top, unless a line there already counts.
    public static func adding(to config: String, home: String) -> String {
        isPresent(in: config, home: home) ? config : line + "\n\n" + config
    }

    /// The arguments of an `Include` line after its keyword: one optional `=`, then words that double quotes can join.
    private static func arguments(_ text: Substring) -> [String] {
        var rest = text.drop(while: { $0 == " " || $0 == "\t" })
        if rest.first == "=" { rest = rest.dropFirst() }
        var words: [String] = []
        var word = ""
        var started = false
        var quoted = false
        for character in rest {
            if quoted {
                if character == "\"" { quoted = false } else { word.append(character) }
            } else if character == "\"" {
                quoted = true
                started = true
            } else if character == " " || character == "\t" {
                if started { words.append(word) }
                word = ""
                started = false
            } else if character == "#" && !started {
                break
            } else {
                word.append(character)
                started = true
            }
        }
        if started { words.append(word) }
        return words
    }

    /// Whether `home`'s `~/.ssh/config` has the line.
    public static func isEnabled(home: URL) -> Bool {
        guard let data = FileManager.default.contents(atPath: home.appendingPathComponent(".ssh/config").path) else { return false }
        return isPresent(in: String(decoding: data, as: UTF8.self), home: home.path)
    }

    /// Adds the line to `home`'s `~/.ssh/config` and returns whether it wrote.
    /// A missing `~/.ssh` is created with mode 700, and a missing config with mode 600.
    /// A config that is a symbolic link is left a link, and its target is written.
    /// The file is replaced whole and keeps its mode.
    public static func enable(home: URL) throws -> Bool {
        let manager = FileManager.default
        let folder = home.appendingPathComponent(".ssh")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var config = folder.appendingPathComponent("config")
        for _ in 0 ..< 32 {
            guard let destination = try? manager.destinationOfSymbolicLink(atPath: config.path) else { break }
            config = URL(fileURLWithPath: destination, relativeTo: config.deletingLastPathComponent()).standardizedFileURL
        }
        if (try? manager.destinationOfSymbolicLink(atPath: config.path)) != nil { throw POSIXError(.ELOOP) }

        var current = ""
        let data: Data?
        do {
            data = try Data(contentsOf: config)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            data = nil
        } catch let error as POSIXError where error.code == .ENOENT {
            data = nil
        }
        if let data {
            guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            current = text
        }
        let updated = adding(to: current, home: home.path)
        guard updated != current else { return false }
        let attributes = try? manager.attributesOfItem(atPath: config.path)
        let mode = attributes?[.posixPermissions] as? Int ?? 0o600
        try AtomicFile.write(Data(updated.utf8), to: config, mode: mode_t(mode))
        return true
    }
}
