import Foundation

/// The updater's settings, from the managed and the machine-wide preferences.
/// A user's own preferences never change what the updater does, so this reads two property list files and nothing else.
public struct UpdateSettings: Codable, Sendable, Equatable {
    public static let domain = "com.victor-software-house.signd"
    /// The preferences of a Mobile Device Management (MDM) profile.
    public static let managedURL = URL(filePath: "/Library/Managed Preferences/\(UpdateSettings.domain).plist")
    /// The preferences `sudo defaults write /Library/Preferences/com.victor-software-house.signd` writes.
    public static let machineURL = URL(filePath: "/Library/Preferences/\(UpdateSettings.domain).plist")
    /// The shortest and longest `update-interval`: 1 hour to 30 days.
    public static let intervalBounds: ClosedRange<TimeInterval> = 3600...2_592_000

    /// Where a setting's value comes from, in order of precedence.
    public enum Source: String, Codable, Sendable {
        case managed
        case machine
        case `default`
    }

    /// Whether the updater installs newer releases; the `updates` setting, on by default.
    public let isEnabled: Bool
    public let enabledSource: Source
    /// How often the updater checks, as written: `update-interval`, 6h by default.
    public let interval: String
    public let intervalSeconds: TimeInterval
    public let intervalSource: Source

    enum CodingKeys: String, CodingKey {
        case isEnabled = "updates"
        case enabledSource = "updatesSource"
        case interval, intervalSeconds, intervalSource
    }

    /// Reads `managed` first and `machine` second.
    /// A value that is not valid for its setting is passed over, as is a missing one.
    public init(managed: URL = UpdateSettings.managedURL, machine: URL = UpdateSettings.machineURL) {
        var enabled: (value: Bool, source: Source) = (true, .default)
        var interval: (text: String, seconds: TimeInterval, source: Source) = ("6h", 21_600, .default)
        // The source with the lowest precedence goes first, so a later one replaces it.
        for (source, values) in [(Source.machine, Self.read(machine)), (Source.managed, Self.read(managed))] {
            if let value = values["updates"] as? Bool { enabled = (value, source) }
            if let text = values["update-interval"] as? String, let seconds = Self.validSeconds(text) { interval = (text, seconds, source) }
        }
        isEnabled = enabled.value
        enabledSource = enabled.source
        self.interval = interval.text
        intervalSeconds = interval.seconds
        intervalSource = interval.source
    }

    private static func read(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return [:] }
        return values
    }

    /// Reads a duration such as `90m`, `6h` or `2d` that is within the bounds.
    static func validSeconds(_ text: String) -> TimeInterval? {
        guard let unit = text.last, let number = Double(text.dropLast()), number >= 0, number.isFinite else { return nil }
        let seconds: TimeInterval? = switch unit {
        case "s": number
        case "m": number * 60
        case "h": number * 3600
        case "d": number * 86400
        default: nil
        }
        guard let seconds, intervalBounds.contains(seconds) else { return nil }
        return seconds
    }
}
