import Foundation

/// A release of signd on GitHub: its tag, and where its `Signd.app.zip` is.
public struct Release: Sendable, Equatable {
    public let tag: String
    public let assetURL: URL
    /// The zip's size in bytes, as the release feed reports it.
    public let assetSize: Int?

    public init(tag: String, assetURL: URL, assetSize: Int? = nil) {
        self.tag = tag
        self.assetURL = assetURL
        self.assetSize = assetSize
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
    /// Downloads to a file and returns where it is, which the caller owns.
    public typealias Downloader = @Sendable (URLRequest) async throws -> (URL, URLResponse)

    /// The largest zip the updater downloads: 200 MB.
    public static let maximumAssetSize = 200_000_000

    /// A session with a 60 second wait for data and 10 minutes for the whole download.
    private static let downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    public static let latestURL = URL(string: "https://api.github.com/repos/victor-software-house/signd/releases/latest")!
    public static let assetName = "Signd.app.zip"

    private let transport: Transport
    private let downloader: Downloader

    /// `transport` reads the release and `downloader` fetches its zip; tests pass ones that never use the network.
    public init(
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
        downloader: Downloader? = nil
    ) {
        self.transport = transport
        // A default argument cannot name the private session, so a nil downloader means the session's.
        self.downloader = downloader ?? { try await Self.downloadSession.download(for: $0) }
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
        return Release(tag: reply.tag, assetURL: asset.url, assetSize: asset.size)
    }

    /// Downloads the release's zip into `directory` and returns its file.
    /// It refuses a zip over `maximumAssetSize`, by the size the feed reports and by the size of the file.
    public func download(_ release: Release, to directory: URL) async throws -> URL {
        if let size = release.assetSize, size > Self.maximumAssetSize {
            throw UpdateError("\(Self.assetName) is \(size) bytes, over the limit of \(Self.maximumAssetSize)")
        }
        let host = release.assetURL.host ?? "the release server"
        let result: (URL, URLResponse)
        do {
            result = try await downloader(URLRequest(url: release.assetURL))
        } catch {
            throw UpdateError("cannot reach \(host): \(error.localizedDescription)")
        }
        let file = result.0
        defer { try? FileManager.default.removeItem(at: file) }
        try Self.requireOK(result.1, from: host)
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attributes?[.size] as? Int else { throw UpdateError("cannot read the size of the downloaded \(Self.assetName)") }
        guard size <= Self.maximumAssetSize else {
            throw UpdateError("the downloaded \(Self.assetName) is \(size) bytes, over the limit of \(Self.maximumAssetSize)")
        }
        let zip = directory.appending(path: Self.assetName)
        do {
            try FileManager.default.moveItem(at: file, to: zip)
        } catch {
            throw UpdateError("cannot save \(Self.assetName): \(error)")
        }
        return zip
    }

    private static func requireOK(_ response: URLResponse, from host: String) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError("\(host) did not answer with the release: status \(status)") }
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        let host = request.url?.host ?? "the release server"
        let result: (Data, URLResponse)
        do {
            result = try await transport(request)
        } catch {
            throw UpdateError("cannot reach \(host): \(error.localizedDescription)")
        }
        try Self.requireOK(result.1, from: host)
        return result.0
    }

    private struct Reply: Decodable {
        struct Asset: Decodable {
            let name: String
            let url: URL
            let size: Int?

            enum CodingKeys: String, CodingKey {
                case name, size
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
