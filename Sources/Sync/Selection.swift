import Foundation
import KeyStore
import OnePassword
import SSHWire
import SystemConfiguration

/// Reads one 1Password item as a key signd serves, or says why it does not.
public enum Selection {
    /// What an SSH Key item comes to.
    public enum Result {
        case key(PrivateKey, name: String, hosts: [String])
        case skipped(SkipKind, String)
    }

    public static let note = "signd"
    public static let keyCategory = "SshKey"
    public static let noteCategory = "SecureNote"

    /// This Mac's `LocalHostName`, in lowercase.
    public static func localHostName() -> String {
        (SCDynamicStoreCopyLocalHostName(nil) as String? ?? "").lowercased()
    }

    /// The key name for an item title: lowercase, with every character other than ASCII letters, digits, `-` and `_` turned into `-`.
    public static func keyName(forTitle title: String) -> String {
        String(title.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "-" })
    }

    /// The separators of a `macs` list.
    static func list(_ text: String) -> [String] {
        text.split { $0 == "," || $0.isWhitespace }.map(String.init)
    }

    /// The separators of a `hosts` list.
    static func hostList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func field(_ item: Item, titled title: String) -> String? {
        item.fields.first { $0.title.lowercased() == title }?.value
    }

    /// Applies design decision 3 to a fetched SSH Key item; `hostName` is this Mac's `LocalHostName` in lowercase.
    public static func read(_ item: Item, hostName: String) -> Result {
        if let macs = field(item, titled: "macs").map(list), !macs.isEmpty, !macs.contains(where: { $0.lowercased() == hostName }) {
            return .skipped(.otherMac, "the macs field does not name this Mac")
        }
        let name = keyName(forTitle: item.title)
        guard StoredKey.isValidName(name) else { return .skipped(.invalidName, "the title gives the key name \"\(name)\", which is not a valid name") }
        let hosts = field(item, titled: "hosts").map(hostList) ?? []
        if let host = hosts.first(where: { !StoredKey.isValidHost($0) }) {
            return .skipped(.invalidHost, "the hosts field holds \"\(host)\", which is not a host pattern")
        }
        guard let pem = item.fields.first(where: { $0.fieldType == "SshKey" })?.value else {
            return .skipped(.invalidKey, "the item has no private key field")
        }
        do throws(ImportError) {
            switch try KeyImport.parse(Data(pem.utf8)) {
            case let .key(key, _): return .key(key, name: name, hosts: hosts)
            case .protected: return .skipped(.invalidKey, "the private key is protected by a passphrase")
            }
        } catch {
            return .skipped(.invalidKey, error.description)
        }
    }
}
