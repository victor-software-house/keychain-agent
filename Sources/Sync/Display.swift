import Foundation
import SystemConfiguration

/// Text from another device or from iCloud, made safe to print.
public enum Display {
    /// `text` without control and format characters, which a name, a host or an error message could use to hide or reorder what a terminal shows.
    public static func clean(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar.properties.generalCategory != .control && scalar.properties.generalCategory != .format {
            result.append(scalar)
        }
        return String(result)
    }
}

/// Facts about the device signd runs on.
public enum ThisDevice {
    /// The device's name: this Mac's `LocalHostName`, in lowercase.
    public static func name() -> String {
        (SCDynamicStoreCopyLocalHostName(nil) as String? ?? "").lowercased()
    }
}
