import Foundation
import OnePassword
import Sync

/// The backup login and logout: it checks the 1Password vault, then has the sync service seal the token to every Mac.
public struct BackupLoginService: Sendable {
    /// The titles of the vaults the service account token lists.
    public typealias VaultLister = @Sendable (_ token: String) async throws -> [String]

    private let sync: SyncService
    private let vaults: VaultLister

    public init(sync: SyncService, vaults: @escaping VaultLister) {
        self.sync = sync
        self.vaults = vaults
    }

    /// Lists the vaults through 1Password, as `version` of signd.
    public init(sync: SyncService, version: String) {
        self.init(sync: sync) { token in
            let client = try await Client(token: token, integrationName: "signd", integrationVersion: version)
            return try await client.vaults().map(\.title)
        }
    }

    /// Checks that the service account lists `vault`, then stores the token on this Mac and seals it to every device.
    /// A vault the account lists but cannot write to shows at the first run.
    public func logIn(token: String, vault: String) async -> SyncResult {
        let titles: [String]
        do {
            titles = try await vaults(token)
        } catch {
            return SyncResult(.failed, "cannot list the vaults of the service account: \(error)")
        }
        guard titles.contains(vault) else {
            return SyncResult(.failed, "the service account does not list a vault named \(vault); create it, grant the account access, or change the backup-vault setting")
        }
        return await sync.logInToBackup(token: Data(token.utf8), vault: vault)
    }

    public func logOut() async -> SyncResult {
        await sync.logOutOfBackup()
    }
}
