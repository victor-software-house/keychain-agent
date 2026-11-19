import AgentServer
import ArgumentParser
import Backup
import Foundation
import KeyStore
import Sync

/// Answers the agent's backup requests with the vault check, the restore and the sync service.
struct BackupAgent: BackupCommands {
    let service: BackupLoginService
    let restorer: BackupRestore
    let sync: SyncService
    let agent: Agent
    let backup: BackupService?
    let tokens: any TokenStore
    let settings: Settings

    func logIn(token: String, vault: String) async -> SyncResult { await service.logIn(token: token, vault: vault) }

    func logOut() async -> SyncResult { await service.logOut() }

    /// The backup's keys, each scope shown as the name of the Mac it came from.
    /// A scope that no device matches stays as it is.
    func list() async -> BackupRestoreList {
        var list = await restorer.list()
        let names = Dictionary(await sync.devices().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for index in list.keys.indices { list.keys[index].scope = names[list.keys[index].scope] ?? list.keys[index].scope }
        return list
    }

    /// Restores the keys into the store, shares each unless `local`, and reloads the agent once.
    func restore(names: [String], all: Bool, local: Bool) async -> BackupRestoreResult {
        var result = await restorer.restore(names: names, all: all)
        guard result.keys.contains(where: { $0.outcome == .restored }) else { return result }
        if !local {
            for index in result.keys.indices where result.keys[index].outcome == .restored {
                let name = result.keys[index].name
                let shared = await sync.share(name)
                switch shared.outcome {
                case .done:
                    break
                case .off:
                    result.keys[index].reason = shared.message ?? "sync is off; \(name) stays on this Mac"
                case .failed:
                    result.keys[index] = RestoredKey(
                        name: name, outcome: .failed, reason: "restored on this Mac, but not shared: \(shared.message ?? "unknown reason"); run signd key share \(name)"
                    )
                }
            }
        }
        await agent.reload()
        await sync.keysDidChange()
        await backup?.keysDidChange()
        return result
    }

    func status() async -> BackupStatus {
        let state = await backup?.snapshot() ?? BackupState.load()
        // With no CloudKit container the agent runs no backup service, so no run is ever due.
        let isOn = backup == nil ? false : isTokenStored()
        return BackupStatus(isOn: isOn, vault: settings.text(.backupVault), state: state, schedule: BackupSchedule(settings: settings))
    }

    /// Whether a token is stored; nil when the keychain cannot be read.
    private func isTokenStored() -> Bool? {
        do {
            guard var token = try tokens.read() else { return false }
            token.resetBytes(in: 0..<token.count)
            return true
        } catch {
            return nil
        }
    }
}

extension RestoredKey {
    /// The line `signd backup restore` prints.
    var line: String {
        switch outcome {
        case .restored: reason.map { "restored \(name): \($0)" } ?? "restored \(name)"
        case .skipped: "skipped \(name): \(reason ?? "no reason")"
        case .failed: "failed \(name): \(reason ?? "no reason")"
        }
    }
}

extension BackupStatus {
    /// The lines `signd status` and `signd backup status` print.
    var lines: [String] {
        var lines: [String]
        switch isOn {
        case true?: lines = ["backup  on, vault \(vault)"]
        case false?: lines = ["backup  off; run signd backup login"]
        case nil: lines = ["backup  not known, vault \(vault)"]
        }
        if let lastRun, let lastOutcome {
            lines.append("last backup  \(lastRun.formatted(.iso8601)) \(lastOutcome.rawValue)\(lastError.map { ": \($0)" } ?? "")")
        }
        if let nextRun { lines.append("next backup  \(nextRun.formatted(.iso8601))") }
        return lines
    }
}

struct BackupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup", abstract: "Log in to and out of the 1Password backup, restore keys from it and show its state.",
        subcommands: [Login.self, Logout.self, Restore.self, Status.self]
    )

    /// The backup's status from the agent, or from the state file with the token unknown when no agent answers.
    static func status(client: AgentClient, settings: Settings) -> BackupStatus {
        client.backupStatus()
            ?? BackupStatus(isOn: nil, vault: settings.text(.backupVault), state: BackupState.load(), schedule: BackupSchedule(settings: settings))
    }

    /// The token as stdin gave it, without its one trailing newline.
    static func token(from input: Data) -> String? {
        var bytes = input
        if bytes.last == 0x0A { bytes.removeLast() }
        guard !bytes.isEmpty else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    /// What stdin gives: the token typed at a terminal with echo off, or everything a pipe carries.
    static func readStandardInput() -> Data {
        guard isatty(STDIN_FILENO) != 0 else { return FileHandle.standardInput.readDataToEndOfFile() }
        var buffer = Data(count: 4096)
        defer { buffer.resetBytes(in: 0..<buffer.count) }
        let read = buffer.withUnsafeMutableBytes { raw in
            readpassphrase("1Password service account token: ", raw.bindMemory(to: CChar.self).baseAddress, raw.count, RPP_ECHO_OFF | RPP_STDIN)
        }
        guard read != nil else { return Data() }
        return Data(buffer.prefix { $0 != 0 })
    }

    struct Login: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Store a 1Password service account token, read from stdin, on every Mac.",
            discussion: "The token that stdin carries is checked against the vault named by the backup-vault setting, then sealed to each Mac's Secure Enclave key."
        )
        // Given only to be refused: a token in an argument shows in the process list and the shell history.
        @Argument(help: .hidden) var argument: String?
        @OptionGroup var colorOption: ColorOption

        func run() throws {
            try run(client: AgentClient(path: defaultSocketPath), settings: Settings()) { BackupCommand.readStandardInput() }
        }

        func run(client: AgentClient, settings: Settings, readInput: () -> Data) throws {
            guard argument == nil else { throw Failure("pass the token on stdin, never as an argument") }
            guard let token = BackupCommand.token(from: readInput()) else { throw Failure("stdin has no token, or one that is not text") }
            let vault = settings.text(.backupVault)
            guard let result = client.logInToBackup(BackupLoginRequest(token: token, vault: vault)) else { throw Failure("the agent does not answer") }
            guard result.outcome == .done else { throw Failure(result.message ?? "the login failed") }
            print(colorOption.standardOutput.success("logged in; the backup uses the vault \(vault)"))
        }
    }

    struct Logout: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete the backup token on every Mac.")
        @OptionGroup var colorOption: ColorOption

        func run() throws {
            guard let result = AgentClient(path: defaultSocketPath).logOutOfBackup() else { throw Failure("the agent does not answer") }
            guard result.outcome == .done else { throw Failure(result.message ?? "the logout failed") }
            print(colorOption.standardOutput.success("logged out"))
        }
    }

    struct Restore: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the keys of the backup, or restore them.",
            discussion: "With no names and no --all, it lists the keys. A restored key is shared with every Mac unless --local. A key the store already has is skipped."
        )
        @Argument(help: "The names of the keys to restore.") var names: [String] = []
        @Flag(help: "Restore every key of the backup.") var all = false
        @Flag(help: "Keep the restored keys on this Mac instead of sharing them through iCloud.") var local = false
        @OptionGroup var output: JSONOption

        func validate() throws {
            if all && !names.isEmpty { throw ValidationError("give key names or --all, not both") }
        }

        func run() throws {
            let client = AgentClient(path: defaultSocketPath)
            if names.isEmpty && !all {
                guard let list = client.backupKeys() else { throw Failure("the agent does not answer") }
                if output.json {
                    try output.print(list)
                } else {
                    for key in list.keys { print([key.name, key.scope, key.fingerprint].joined(separator: "  ")) }
                }
                if let failure = list.failure { throw Failure(failure) }
                return
            }
            guard let result = client.restoreBackupKeys(names: names, all: all, local: local) else { throw Failure("the agent does not answer") }
            if output.json {
                try output.print(result)
            } else {
                let out = output.colorOption.standardOutput
                for key in result.keys {
                    switch key.outcome {
                    case .restored: print(out.success(key.line))
                    case .skipped: print(out.warning(key.line))
                    case .failed: print(out.failure(key.line))
                    }
                }
            }
            if let failure = result.failure { throw Failure(failure) }
            if result.keys.contains(where: { $0.outcome == .failed }) { throw ExitCode.failure }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show whether the backup is on, its last run and its next run.")
        @OptionGroup var output: JSONOption

        func run() throws {
            let status = BackupCommand.status(client: AgentClient(path: defaultSocketPath), settings: Settings())
            if output.json {
                try output.print(status)
            } else {
                for line in status.lines { print(line) }
            }
        }
    }
}
