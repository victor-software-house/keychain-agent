import Darwin
import Foundation

/// The directory where the updater unpacks a download, by design decision 4.
/// `/Library/Caches` is writable by admins, so nothing is staged there.
public struct Staging: Sendable {
    public static let defaultRoot = URL(filePath: "/Library/Application Support/signd/update", directoryHint: .isDirectory)

    public let root: URL
    /// The user that may own a component of the path besides root, and that owns every file of a staged app.
    /// It is 0 in production, and tests pass the CI user.
    public let owner: uid_t
    /// The group of every file of a staged app: wheel, 0, in production.
    public let group: gid_t

    public init(root: URL = Staging.defaultRoot, owner: uid_t = 0, group: gid_t = 0) {
        self.root = root
        self.owner = owner
        self.group = group
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

    /// Gives `app` and every file in it the expected owner and group, and clears the setuid and setgid bits and the group and other write bits.
    ///
    /// A zip records the owners of the machine that built it, and `ditto` run as root keeps them.
    /// Neither owners nor modes are part of the code signature, so this does not change the signature check.
    public func seal(_ app: URL) throws {
        try visit(app) { path, info in
            guard lchown(path, owner, group) == 0 else { throw UpdateError("cannot change the owner of \(path): \(Self.reason())") }
            // A symbolic link has no mode of its own, and chmod would follow it.
            guard info.st_mode & S_IFMT != S_IFLNK else { return }
            guard chmod(path, info.st_mode & 0o755) == 0 else { throw UpdateError("cannot change the mode of \(path): \(Self.reason())") }
        }
    }

    /// Checks that `app` and every file in it have the expected owner and group.
    /// None may have a setuid or setgid bit or be writable by group or others.
    public func check(_ app: URL) throws {
        try visit(app) { path, info in
            guard info.st_uid == owner, info.st_gid == group else {
                throw UpdateError("\(path) belongs to user \(info.st_uid) and group \(info.st_gid), so the updater does not install it")
            }
            // 0o6022 is the setuid, setgid, group write and other write bits.
            guard info.st_mode & 0o6022 == 0 else {
                throw UpdateError("\(path) is writable by group or others, or has a setuid or setgid bit, so the updater does not install it")
            }
        }
    }

    /// Calls `body` with the path and the `lstat` result of `app` and of everything in it, without following a symbolic link.
    private func visit(_ app: URL, _ body: (_ path: String, _ info: stat) throws -> Void) throws {
        guard let enumerator = FileManager.default.enumerator(atPath: app.path) else { throw UpdateError("cannot read \(app.lastPathComponent)") }
        var paths = [app.path]
        while let relative = enumerator.nextObject() as? String { paths.append(app.path + "/" + relative) }
        for path in paths {
            var info = stat()
            guard lstat(path, &info) == 0 else { throw UpdateError("cannot read \(path): \(Self.reason())") }
            try body(path, info)
        }
    }

    /// Walks the root's path from `/`, makes the components that are missing, and checks each one.
    private func prepareRoot() throws {
        // The path is walked as given: standardizing it would strip /private from a resolved path.
        let components = Array(root.pathComponents.dropFirst())
        guard !components.contains("..") else { throw UpdateError("\(root.path) has a .. component, so the updater stages nothing under it") }
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
