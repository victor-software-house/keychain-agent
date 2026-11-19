import Darwin
import Foundation

/// The directory where the updater unpacks a download, by design decision 4.
/// `/Library/Caches` is writable by admins, so nothing is staged there.
public struct Staging: Sendable {
    public static let defaultRoot = URL(filePath: "/Library/Application Support/signd/update", directoryHint: .isDirectory)

    public let root: URL
    /// The user that may own a component of the path besides root.
    /// It is 0 in production, and tests pass the CI user.
    public let owner: uid_t

    public init(root: URL = Staging.defaultRoot, owner: uid_t = 0) {
        self.root = root
        self.owner = owner
    }

    /// Makes a fresh directory in the root, which is created with mode 0700 when it is missing.
    /// It refuses to go on when any path component from `/` down is a symbolic link, is not a directory, or belongs to neither root nor `owner`.
    public func makeDirectory() throws -> URL {
        try prepareRoot()
        var template = Array(root.appending(path: "XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw UpdateError("cannot make a staging directory in \(root.path): \(Self.reason())") }
        return URL(filePath: String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self), directoryHint: .isDirectory)
    }

    /// Unpacks `zip` into `directory` with `ditto`.
    public func unpack(_ zip: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() } catch { throw UpdateError("cannot run ditto: \(error)") }
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("ditto cannot unpack \(zip.lastPathComponent): \(String(decoding: output, as: UTF8.self))")
        }
    }

    /// Walks the root's path from `/`, makes the components that are missing, and checks each one.
    private func prepareRoot() throws {
        let components = Array(root.standardizedFileURL.pathComponents.dropFirst())
        var path = ""
        for (index, component) in components.enumerated() {
            path += "/" + component
            var info = stat()
            if lstat(path, &info) != 0 {
                let isLeaf = index == components.count - 1
                guard errno == ENOENT, mkdir(path, isLeaf ? 0o700 : 0o755) == 0, lstat(path, &info) == 0 else {
                    throw UpdateError("cannot use \(path) for staging: \(Self.reason())")
                }
            }
            guard info.st_mode & S_IFMT != S_IFLNK else { throw UpdateError("\(path) is a symbolic link, so the updater stages nothing under it") }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw UpdateError("\(path) is not a directory, so the updater stages nothing under it") }
            guard info.st_uid == 0 || info.st_uid == owner else {
                throw UpdateError("\(path) belongs to user \(info.st_uid), so the updater stages nothing under it")
            }
        }
    }

    private static func reason() -> String { String(cString: strerror(errno)) }
}
