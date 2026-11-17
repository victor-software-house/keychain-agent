import Foundation

/// signd's settings, in the user defaults domain `com.victor-software-house.signd`.
public struct Settings: Sendable {
    public static let domain = "com.victor-software-house.signd"

    /// A setting signd reads, with its default.
    public enum Key: String, CaseIterable, Sendable {
        case keyLifetime = "key-lifetime"

        public var defaultValue: String {
            switch self {
            case .keyLifetime: "1h"
            }
        }
    }

    public init() {}

    // CFPreferences names the domain explicitly: through the cask's link, signd has no bundle
    // identifier, and UserDefaults refuses a suite named after the bundle's own identifier.
    public func value(_ key: Key) -> String? {
        CFPreferencesAppSynchronize(Self.domain as CFString)
        return CFPreferencesCopyAppValue(key.rawValue as CFString, Self.domain as CFString) as? String
    }

    public func set(_ key: Key, _ value: String) throws(SettingsError) {
        switch key {
        case .keyLifetime:
            guard Self.seconds(value) != nil else { throw .invalid(key.rawValue, value) }
        }
        write(key, value as CFString)
    }

    public func unset(_ key: Key) { write(key, nil) }

    private func write(_ key: Key, _ value: CFPropertyList?) {
        CFPreferencesSetAppValue(key.rawValue as CFString, value, Self.domain as CFString)
        CFPreferencesAppSynchronize(Self.domain as CFString)
    }

    /// How long a private key stays in memory after its last signature.
    public var keyLifetime: TimeInterval {
        value(.keyLifetime).flatMap(Self.seconds) ?? Self.seconds(Key.keyLifetime.defaultValue)!
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
