import AgentServer
import ArgumentParser
import Backup
import Foundation
import KeyStore
import Sync

/// Answers the agent's backup requests with the vault check and the sync service.
struct BackupAgent: BackupLogin {
    let service: BackupLoginService

    func login(token: String, vault: String) async -> SyncResult { await service.login(token: token, vault: vault) }

    func logout() async -> SyncResult { await service.logout() }
}

struct BackupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup", abstract: "Log in to and out of the 1Password backup.", subcommands: [Login.self, Logout.self]
    )

    /// The token as stdin gave it, without its one trailing newline.
    static func token(from input: Data) -> String? {
        var bytes = input
        if bytes.last == 0x0A { bytes.removeLast() }
        guard !bytes.isEmpty else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    struct Login: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Store a 1Password service account token, read from stdin, on every Mac.",
            discussion: "The token that stdin carries is checked against the vault named by the backup-vault setting, then sealed to each Mac's Secure Enclave key."
        )
        // Given only to be refused: a token in an argument shows in the process list and the shell history.
        @Argument(help: .hidden) var argument: String?

        func run() throws {
            try run(client: AgentClient(path: defaultSocketPath), settings: Settings()) { FileHandle.standardInput.readDataToEndOfFile() }
        }

        func run(client: AgentClient, settings: Settings, readInput: () -> Data) throws {
            guard argument == nil else { throw Failure("pass the token on stdin, never as an argument") }
            guard let token = BackupCommand.token(from: readInput()) else { throw Failure("stdin has no token, or one that is not text") }
            let vault = settings.text(.backupVault)
            guard let result = client.backupLogin(BackupLoginRequest(token: token, vault: vault)) else { throw Failure("the agent does not answer") }
            guard result.outcome == .done else { throw Failure(result.message ?? "the login failed") }
            print("logged in; the backup uses the vault \(vault)")
        }
    }

    struct Logout: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete the backup token on every Mac.")

        func run() throws {
            guard let result = AgentClient(path: defaultSocketPath).backupLogout() else { throw Failure("the agent does not answer") }
            guard result.outcome == .done else { throw Failure(result.message ?? "the logout failed") }
            print("logged out")
        }
    }
}
