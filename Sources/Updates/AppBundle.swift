import Darwin
import Foundation
import Security

/// An app bundle on disk: the installed Signd.app, or one the updater unpacked.
/// It reads another bundle's files, never `Bundle.main`, which signd has none of through the cask's link.
public struct AppBundle: Sendable {
    public static let identifier = "com.victor-software-house.signd"

    public let url: URL

    public init(url: URL) { self.url = url }

    /// The executable the agent runs from.
    public var executable: URL { url.appending(path: "Contents/MacOS/signd") }

    /// `CFBundleShortVersionString` in the bundle's `Info.plist`, or nil when it cannot be read.
    public var version: String? {
        guard let data = try? Data(contentsOf: url.appending(path: "Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    /// Checks the bundle with strict validation against one requirement: signed by Apple's anchor, notarized, with signd's identifier and `team`.
    public func verify(team: String) throws {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == false else {
            throw UpdateError("the download has no \(url.lastPathComponent), or it is a symbolic link")
        }
        var staticRef: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticRef) == errSecSuccess, let code = staticRef else {
            throw UpdateError("cannot read the signature of \(url.lastPathComponent)")
        }
        let text = "anchor apple generic and notarized and identifier \"\(Self.identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        var requirementRef: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirementRef) == errSecSuccess, let requirement = requirementRef else {
            throw UpdateError("cannot build the signature requirement for team \(team)")
        }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
        guard status == errSecSuccess else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            throw UpdateError("\(url.lastPathComponent) is not notarized and signed by team \(team) as \(Self.identifier): \(reason)")
        }
    }

    /// Checks that the bundle's version is `expected`, so an older build under a newer tag never installs.
    public func requireVersion(_ expected: String) throws {
        guard version == expected else {
            throw UpdateError("\(url.lastPathComponent) is version \(version ?? "unknown"), not \(expected)")
        }
    }

    /// Exchanges this bundle's `Contents` with `other`'s in one step, then deletes the old `Contents`.
    /// A swap that fails leaves this bundle whole.
    public func swapContents(with other: AppBundle) throws {
        let installed = url.appending(path: "Contents")
        let new = other.url.appending(path: "Contents")
        guard renamex_np(new.path, installed.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateError("cannot swap the new \(other.url.lastPathComponent) in: \(String(cString: strerror(errno)))")
        }
        // The old Contents is at the new path now, and a failed delete leaves only a file in the staging directory.
        try? FileManager.default.removeItem(at: new)
    }

    /// The team identifier of the running code's own signature.
    public static func runningTeam() throws -> String {
        var selfRef: SecCode?
        var staticRef: SecStaticCode?
        var informationRef: CFDictionary?
        guard SecCodeCopySelf([], &selfRef) == errSecSuccess, let running = selfRef,
              SecCodeCopyStaticCode(running, [], &staticRef) == errSecSuccess, let code = staticRef,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &informationRef) == errSecSuccess,
              let team = (informationRef as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw UpdateError("the updater's own signature has no team identifier, so it cannot tell which updates to trust: an unsigned build does not update")
        }
        return team
    }
}
