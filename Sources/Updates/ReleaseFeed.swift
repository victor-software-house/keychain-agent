import Foundation

/// A release of signd on GitHub: its tag, and where its `Signd.app.zip` is.
public struct Release: Sendable, Equatable {
    public let tag: String
    public let assetURL: URL

    public init(tag: String, assetURL: URL) {
        self.tag = tag
        self.assetURL = assetURL
    }

    /// The tag without its leading `v`, which the app's `CFBundleShortVersionString` equals.
    public var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }

    /// Whether the tag is a newer version than `installed`, compared number by number.
    /// A version that is not numbers separated by dots is not newer.
    public func isNewer(than installed: String) -> Bool {
        guard let new = Self.numbers(version), let old = Self.numbers(installed) else { return false }
        let width = max(new.count, old.count)
        func padded(_ numbers: [Int]) -> [Int] { numbers + Array(repeating: 0, count: width - numbers.count) }
        return padded(old).lexicographicallyPrecedes(padded(new))
    }

    private static func numbers(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part in part.allSatisfy { $0.isASCII && $0.isNumber } ? Int(part) : nil }
        return numbers.count == parts.count ? numbers : nil
    }
}

/// The latest release of signd, from the GitHub API, and the download of its zip.
/// Neither request carries a credential.
public struct ReleaseFeed: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let latestURL = URL(string: "https://api.github.com/repos/victor-software-house/signd/releases/latest")!
    public static let assetName = "Signd.app.zip"

    private let transport: Transport

    /// `transport` sends each request; tests pass one that never uses the network.
    public init(transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.transport = transport
    }

    /// The latest release, with the URL of its `Signd.app.zip`.
    public func latest() async throws -> Release {
        var request = URLRequest(url: Self.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data = try await fetch(request)
        let reply: Reply
        do {
            reply = try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw UpdateError("cannot read the latest release: \(error)")
        }
        guard let asset = reply.assets.first(where: { $0.name == Self.assetName }) else {
            throw UpdateError("the latest release \(reply.tag) has no \(Self.assetName)")
        }
        return Release(tag: reply.tag, assetURL: asset.url)
    }

    /// Downloads the release's zip into `directory` and returns its file.
    public func download(_ release: Release, to directory: URL) async throws -> URL {
        let data = try await fetch(URLRequest(url: release.assetURL))
        let zip = directory.appending(path: Self.assetName)
        do {
            try data.write(to: zip)
        } catch {
            throw UpdateError("cannot save \(Self.assetName): \(error)")
        }
        return zip
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        let host = request.url?.host ?? "the release server"
        let result: (Data, URLResponse)
        do {
            result = try await transport(request)
        } catch {
            throw UpdateError("cannot reach \(host): \(error.localizedDescription)")
        }
        guard let status = (result.1 as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw UpdateError("\(host) did not answer with the release: status \((result.1 as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return result.0
    }

    private struct Reply: Decodable {
        struct Asset: Decodable {
            let name: String
            let url: URL

            enum CodingKeys: String, CodingKey {
                case name
                case url = "browser_download_url"
            }
        }

        let tag: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case assets
        }
    }
}
