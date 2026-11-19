import Darwin
import Foundation

/// What the updater keeps about its last check, in `update.json`.
/// It contains no secret.
public struct UpdateState: Codable, Sendable, Equatable {
    /// How a check ended.
    public enum Outcome: String, Codable, Sendable {
        case upToDate = "up-to-date"
        case installed
        case failed
        /// `updates` is off, so the check made no request.
        case off
    }

    /// When the check began.
    public var lastCheck: Date?
    /// The installed version after the check.
    public var installed: String?
    /// The version this check replaced; nil when it installed nothing.
    public var previous: String?
    /// When this check finished the install; nil when it installed nothing.
    public var installedAt: Date?
    /// The version of the latest release, when the check found it.
    public var latest: String?
    public var outcome: Outcome?
    public var error: String?

    public init() {}

    /// `/Library/Application Support/signd/update.json`, which every user can read.
    public static let defaultURL = URL(filePath: "/Library/Application Support/signd/update.json")

    /// The state in `url`, or an empty one when the file is missing or unreadable.
    public static func load(from url: URL = UpdateState.defaultURL) -> UpdateState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(UpdateState.self, from: data) else { return UpdateState() }
        return state
    }

    /// Writes the state in one step, mode 0644: a temporary file in the same directory, renamed over the target.
    public func save(to url: URL = UpdateState.defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o644]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temporary.path, url.path) != 0 {
            let reason = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: reason) ?? .EIO)
        }
    }
}

/// What `signd status` shows about updates: the settings, and the state of the last check.
public struct UpdateStatus: Codable, Sendable, Equatable {
    public let settings: UpdateSettings
    public let state: UpdateState

    public init(settings: UpdateSettings = UpdateSettings(), state: UpdateState = UpdateState.load()) {
        self.settings = settings
        self.state = state
    }
}
