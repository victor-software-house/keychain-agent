import Foundation

/// signd's settings, in the user defaults domain `com.victor-software-house.signd`.
public struct Settings: Sendable {
    public static let domain = "com.victor-software-house.signd"

    /// A setting signd reads, with its default.
    public enum Key: String, CaseIterable, Sendable {
        case keyLifetime = "key-lifetime"
        case interval

        public var defaultValue: String {
            switch self {
            case .keyLifetime: "1h"
            case .interval: "5m"
            }
        }
    }

    /// Where a setting's value comes from, in order of precedence.
    public enum Source: String, Codable, Sendable {
        /// `signd config set` on this Mac.
        case local
        /// The `signd` note in 1Password, for every Mac.
        case note
        case `default`
    }

    /// A setting's value, its length in seconds, and where it came from.
    public struct Resolved: Sendable, Equatable {
        public let value: String
        public let seconds: TimeInterval
        public let source: Source
    }

    public init() {}

    // CFPreferences names the domain explicitly: through the cask's link, signd has no bundle
    // identifier, and UserDefaults refuses a suite named after the bundle's own identifier.
    public func value(_ key: Key) -> String? {
        CFPreferencesAppSynchronize(Self.domain as CFString)
        return CFPreferencesCopyAppValue(key.rawValue as CFString, Self.domain as CFString) as? String
    }

    public func set(_ key: Key, _ value: String) throws(SettingsError) {
        guard Self.validSeconds(key, value) != nil else { throw .invalid(key.rawValue, value) }
        write(key, value as CFString)
    }

    public func unset(_ key: Key) { write(key, nil) }

    private func write(_ key: Key, _ value: CFPropertyList?) {
        CFPreferencesSetAppValue(key.rawValue as CFString, value, Self.domain as CFString)
        CFPreferencesAppSynchronize(Self.domain as CFString)
    }

    /// A setting's value: the local one, else the `signd` note's in `fleet`, else the default.
    /// A value that is not a valid duration for the setting is passed over.
    public func resolve(_ key: Key, fleet: [String: String] = [:]) -> Resolved {
        let candidates: [(String?, Source)] = [(value(key), .local), (fleet[key.rawValue], .note)]
        for (value, source) in candidates {
            if let value, let seconds = Self.validSeconds(key, value) { return Resolved(value: value, seconds: seconds, source: source) }
        }
        let value = key.defaultValue
        return Resolved(value: value, seconds: Self.seconds(value)!, source: .default)
    }

    /// A duration that suits `key`: the interval must be above zero.
    public static func validSeconds(_ key: Key, _ text: String) -> TimeInterval? {
        guard let seconds = seconds(text) else { return nil }
        return key == .interval && seconds <= 0 ? nil : seconds
    }

    /// Reads a duration such as `90s`, `30m`, `1h` or `2d`.
    public static func seconds(_ text: String) -> TimeInterval? {
        guard let unit = text.last, let number = Double(text.dropLast()), number >= 0 else { return nil }
        return switch unit {
        case "s": number
        case "m": number * 60
        case "h": number * 3600
        case "d": number * 86400
        default: nil
        }
    }
}

public enum SettingsError: Error, Sendable, CustomStringConvertible {
    case invalid(String, String)

    public var description: String {
        switch self {
        case let .invalid(key, value): "invalid value \(value) for \(key): use a duration such as 90s, 30m, 1h or 2d"
        }
    }
}
