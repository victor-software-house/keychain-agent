import OnePassword

/// The calls a run makes to the 1Password vault, so a test needs no 1Password.
public protocol BackupVault: Sendable {
    /// Every item of the vault, as overviews.
    func list() async throws -> [ItemOverview]
    /// Full items, in the order of `ids`.
    func items(_ ids: [String]) async throws -> [ItemResult]
    /// New items, in the order of `contents`.
    func create(_ contents: [ItemContent]) async throws -> [ItemResult]
    /// Sets one item's content and returns the item as saved.
    func put(_ id: String, _ content: ItemContent) async throws -> Item
    /// Deletes items and returns the failure of each one it could not delete.
    func delete(_ ids: [String]) async throws -> [String: ItemFailure]
    func archive(_ id: String) async throws
}

/// Opens the vault named `vault` with a service account token.
public typealias BackupVaultOpener = @Sendable (_ token: String, _ vault: String) async throws -> any BackupVault

/// A vault reached through swift-onepassword.
public struct OnePasswordVault: BackupVault {
    let client: Client
    let vaultID: String

    /// The opener the agent uses, as `version` of signd.
    public static func opener(version: String) -> BackupVaultOpener {
        { token, vault in
            let client = try await Client(token: token, integrationName: "signd", integrationVersion: version)
            guard let found = try await client.vaults().first(where: { $0.title == vault }) else {
                throw BackupFailure("the service account does not list a vault named \(vault)")
            }
            return OnePasswordVault(client: client, vaultID: found.id)
        }
    }

    public func list() async throws -> [ItemOverview] { try await client.items(inVault: vaultID) }
    public func items(_ ids: [String]) async throws -> [ItemResult] { try await client.items(ids, inVault: vaultID) }
    public func create(_ contents: [ItemContent]) async throws -> [ItemResult] { try await client.create(contents, inVault: vaultID) }
    public func put(_ id: String, _ content: ItemContent) async throws -> Item { try await client.update(id, inVault: vaultID, to: content) }
    public func delete(_ ids: [String]) async throws -> [String: ItemFailure] { try await client.delete(ids, inVault: vaultID) }
    public func archive(_ id: String) async throws { try await client.archive(id, inVault: vaultID) }
}

/// A failure of a run, with the message `signd status` shows.
struct BackupFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
