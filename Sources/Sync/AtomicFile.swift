import Darwin
import Foundation

/// Writes a file in one step.
/// It writes a temporary file in the same directory, then renames it over the target.
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL, mode: mode_t) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: Int(mode)]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temporary.path, url.path) != 0 {
            let reason = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: reason) ?? .EIO)
        }
    }
}
