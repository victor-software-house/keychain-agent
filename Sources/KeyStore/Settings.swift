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
            case .interval: "2s"
            }
        }

        /// The shortest and longest value, in seconds: an interval of 1 second to 1 hour, and a key lifetime of 1 second to 30 days.
        public var bounds: ClosedRange<TimeInterval> {
            switch self {
            case .keyLifetime: 1...2_592_000
            case .interval: 1...3600
            }
        }
    }

    /// Where a setting's value comes from, in order of precedence.
    public enum Source: String, Codable, Sendable {
        /// `signd config set` on this Mac.
        case local
        case `default`
    }

    /// A setting's value, its length in seconds, and where it came from.
    public struct Resolved: Sendable, Equatable {
        public let value: String
        public let seconds: TimeInterval
        public let source: Source
    }

    /// A local value that `resolve` passes over, and why.
    public struct Ignored: Codable, Sendable, Equatable {
        public let key: String
        public let value: String
        public let reason: String

        public init(key: String, value: String, reason: String) {
            self.key = key
            self.value = value
            self.reason = reason
        }
    }

    private let local: @Sendable (Key) -> String?

    public init() { local = Self.preference }

    /// Reads the local values from `local` instead of the user defaults, so a test needs no defaults.
    init(local: @escaping @Sendable (Key) -> String?) { self.local = local }

    // CFPreferences takes the domain explicitly.
    // Through the cask's link, signd has no bundle identifier.
    // UserDefaults refuses a suite called by the bundle's own identifier.
    public func value(_ key: Key) -> String? { local(key) }

    private static func preference(_ key: Key) -> String? {
        CFPreferencesAppSynchronize(Self.domain as CFString)
        return CFPreferencesCopyAppValue(key.rawValue as CFString, Self.domain as CFString) as? String
    }

    /// The local values that are not valid durations for their setting, which `resolve` passes over.
    public func ignored() -> [Ignored] {
        Key.allCases.compactMap { key in
            guard let value = value(key), Self.validSeconds(key, value) == nil else { return nil }
            return Ignored(
                key: key.rawValue, value: value,
                reason: "not a duration such as 90s, 30m, 1h or 2d from \(Int(key.bounds.lowerBound)) to \(Int(key.bounds.upperBound)) seconds"
            )
        }
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

    /// A setting's value: the local one, else the default. A local value that is not a valid duration for the setting is passed over.
    public func resolve(_ key: Key) -> Resolved {
        if let value = value(key), let seconds = Self.validSeconds(key, value) { return Resolved(value: value, seconds: seconds, source: .local) }
        let value = key.defaultValue
        return Resolved(value: value, seconds: Self.seconds(value)!, source: .default)
    }

    /// A duration that suits `key`, within its bounds.
    public static func validSeconds(_ key: Key, _ text: String) -> TimeInterval? {
        guard let seconds = seconds(text), key.bounds.contains(seconds) else { return nil }
        return seconds
    }

    /// Reads a duration such as `90s`, `30m`, `1h` or `2d`.
    public static func seconds(_ text: String) -> TimeInterval? {
        guard let unit = text.last, let number = Double(text.dropLast()), number >= 0, number.isFinite else { return nil }
        let seconds: TimeInterval? = switch unit {
        case "s": number
        case "m": number * 60
        case "h": number * 3600
        case "d": number * 86400
        default: nil
        }
        return seconds.flatMap { $0.isFinite ? $0 : nil }
    }
}

public enum SettingsError: Error, Sendable, CustomStringConvertible {
    case invalid(String, String)

    public var description: String {
        switch self {
        case let .invalid(key, value):
            let range = Settings.Key(rawValue: key).map { ", from \(Int($0.bounds.lowerBound)) to \(Int($0.bounds.upperBound)) seconds" } ?? ""
            return "invalid value \(value) for \(key): use a duration such as 90s, 30m, 1h or 2d\(range)"
        }
    }
}
