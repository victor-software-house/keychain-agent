import KeyStore
import OnePassword

/// What a check reads from 1Password, so tests need no network.
public protocol OnePasswordSource: Sendable {
    func vaults() async throws(OnePasswordError) -> [VaultOverview]
    func items(vaultID: String) async throws(OnePasswordError) -> [ItemOverview]
    func item(vaultID: String, itemID: String) async throws(OnePasswordError) -> Item
}

extension Client: OnePasswordSource {}

/// Opens a source for a service account token.
public typealias SourceFactory = @Sendable (_ token: String) async throws(OnePasswordError) -> any OnePasswordSource

public enum LiveSource {
    /// Seals a synced key with the Secure Enclave, with the source `1password`.
    public static let wrapper: KeyWrapper = { name, key, comment, hosts throws(StoreError) in
        try KeychainStore.makeWrappedKey(name: name, privateKey: key, comment: comment, hosts: hosts, source: StoredKey.syncedSource)
    }

    /// The factory that opens the real 1Password client.
    public static func factory(version: String) -> SourceFactory {
        { token throws(OnePasswordError) in
            try await Client(token: token, integrationName: "signd", integrationVersion: version)
        }
    }
}
