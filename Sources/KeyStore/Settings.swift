import Darwin
import Foundation

/// signd's settings, in the user defaults domain `com.victor-software-house.signd`.
public struct Settings: Sendable {
    public static let domain = "com.victor-software-house.signd"

    /// The Darwin notification that a command posts after it writes a setting, so the agent applies the change at once.
    public static let changedNotification = "com.victor-software-house.signd.settings-changed"

    /// A setting signd reads, with its default.
    public enum Key: String, CaseIterable, Sendable {
        case keyLifetime = "key-lifetime"
        case interval
        case backupVault = "backup-vault"
        case backupRemoved = "backup-removed"
        case backupDelay = "backup-delay"
        case backupMinInterval = "backup-min-interval"
        case backupMaxInterval = "backup-max-interval"

        public var defaultValue: String {
            switch self {
            case .keyLifetime: "1h"
            case .interval: "2s"
            case .backupVault: "signd"
            case .backupRemoved: "delete"
            case .backupDelay: "5m"
            case .backupMinInterval: "1h"
            case .backupMaxInterval: "1d"
            }
        }

        /// The values a text setting accepts, or nil when any name does.
        public var choices: [String]? {
            switch self {
            case .backupRemoved: ["delete", "archive", "keep"]
            case .keyLifetime, .interval, .backupVault, .backupDelay, .backupMinInterval, .backupMaxInterval: nil
            }
        }

        /// The shortest and longest value, in seconds: an interval of 1 second to 1 hour, and a key lifetime of 1 second to 30 days.
        /// The backup delay is 1 second to 1 hour.
        /// Its minimum interval is 1 second to 1 day, and its maximum interval is 1 second to 30 days.
        /// A text setting has no bounds.
        public var bounds: ClosedRange<TimeInterval>? {
            switch self {
            case .keyLifetime: 1...2_592_000
            case .interval, .backupDelay: 1...3600
            case .backupMinInterval: 1...86400
            case .backupMaxInterval: 1...2_592_000
            case .backupVault, .backupRemoved: nil
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

    /// The local values that are not valid for their setting, which `resolve` and `text` pass over.
    public func ignored() -> [Ignored] {
        Key.allCases.compactMap { key in
            guard let value = value(key), !Self.isValid(key, value) else { return nil }
            let reason = key.bounds.map {
                "not a duration such as 90s, 30m, 1h or 2d from \(Int($0.lowerBound)) to \(Int($0.upperBound)) seconds"
            } ?? key.choices.map { "not one of \($0.joined(separator: ", "))" } ?? "not a name: use text with no control characters"
            return Ignored(key: key.rawValue, value: value, reason: reason)
        }
    }

    public func set(_ key: Key, to value: String) throws(SettingsError) {
        guard Self.isValid(key, value) else { throw .invalid(key.rawValue, value) }
        write(key, value as CFString)
    }

    public func unset(_ key: Key) { write(key, nil) }

    private func write(_ key: Key, _ value: CFPropertyList?) {
        CFPreferencesSetAppValue(key.rawValue as CFString, value, Self.domain as CFString)
        CFPreferencesAppSynchronize(Self.domain as CFString)
        notify_post(Self.changedNotification)
    }

    /// A setting's value: the local one, else the default. A local value that is not a valid duration for the setting is passed over.
    /// The seconds are 0 for a text setting, which `text` reads without them.
    public func resolve(_ key: Key) -> Resolved {
        if let value = value(key), Self.isValid(key, value) { return Resolved(value: value, seconds: Self.seconds(value) ?? 0, source: .local) }
        let value = key.defaultValue
        return Resolved(value: value, seconds: Self.seconds(value) ?? 0, source: .default)
    }

    /// A text setting's value: the local one, else the default. A local value that is not valid text is passed over.
    public func text(_ key: Key) -> String { resolve(key).value }

    /// Whether `text` suits `key`.
    /// A duration must be within its bounds, and a setting with choices takes one of them.
    /// Another text setting takes a non-empty name with no control characters.
    static func isValid(_ key: Key, _ text: String) -> Bool {
        if let choices = key.choices { return choices.contains(text) }
        guard key.bounds != nil else { return !text.isEmpty && !text.unicodeScalars.contains { $0.properties.generalCategory == .control } }
        return validSeconds(key, text) != nil
    }

    /// A duration that suits `key`, within its bounds.
    public static func validSeconds(_ key: Key, _ text: String) -> TimeInterval? {
        guard let bounds = key.bounds, let seconds = seconds(text), bounds.contains(seconds) else { return nil }
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
            let setting = Settings.Key(rawValue: key)
            if let choices = setting?.choices { return "invalid value \(value) for \(key): use one of \(choices.joined(separator: ", "))" }
            if let setting, setting.bounds == nil { return "invalid value \(value) for \(key): use a name with no control characters" }
            let range = setting?.bounds.map { ", from \(Int($0.lowerBound)) to \(Int($0.upperBound)) seconds" } ?? ""
            return "invalid value \(value) for \(key): use a duration such as 90s, 30m, 1h or 2d\(range)"
        }
    }
}
