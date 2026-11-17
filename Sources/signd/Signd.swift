import AgentServer
import ArgumentParser
import Foundation
import KeyStore
import OnePassword
import os
import ServiceManagement
import SSHWire
import Sync

@main
struct Signd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "An SSH agent for keys only its signed app can use.",
        version: signdVersion,
        subcommands: [KeyCommand.self, Login.self, Logout.self, SyncNow.self, Status.self, Config.self, Service.self, Serve.self]
    )
}

/// A failure the command reports and exits non-zero for.
struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
    init(_ error: some Error) { description = String(describing: error) }
}

struct JSONOption: ParsableArguments {
    @Flag(help: "Print one JSON document on stdout.")
    var json = false

    func print(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        Swift.print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}

/// A key as commands print it.
struct KeySummary: Encodable {
    let name: String
    let type: String
    let algorithm: String
    let fingerprint: String
    let comment: String
    let hosts: [String]
    let source: String
    let publicKey: String
    let created: Date

    init(_ key: StoredKey) {
        let publicKey = key.publicKey
        name = key.name
        type = key.kind.rawValue
        algorithm = publicKey?.keyType ?? "?"
        fingerprint = publicKey?.fingerprint ?? "?"
        comment = key.comment
        hosts = key.hosts
        source = key.source
        self.publicKey = publicKey?.openSSHLine(comment: key.displayComment) ?? ""
        created = key.created
    }
}

func storedKeys() throws -> [StoredKey] {
    do { return try KeychainStore().list() } catch { throw Failure(error) }
}

func storedKey(_ name: String) throws -> StoredKey {
    guard let key = try storedKeys().first(where: { $0.name == name }) else { throw Failure(StoreError.notFound(name)) }
    return key
}

struct KeyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "key", abstract: "Create, list, show and delete keys.", subcommands: [Create.self, Import.self, List.self, Show.self, Delete.self])

    /// The kinds of key `key create` makes.
    enum KeyType: String, ExpressibleByArgument, CaseIterable {
        case secureEnclave = "secure-enclave"
        case ed25519
        case rsa3072 = "rsa-3072"
        case rsa4096 = "rsa-4096"

        var generated: GeneratedKeyType? {
            switch self {
            case .secureEnclave: nil
            case .ed25519: .ed25519
            case .rsa3072: .rsa3072
            case .rsa4096: .rsa4096
            }
        }
    }

    /// Checks a new key's name and host patterns, and that the name is free.
    static func checkNew(name: String, hosts: [String], store: KeychainStore) throws {
        guard StoredKey.isValidName(name) else { throw Failure(StoreError.invalidName(name)) }
        if let host = hosts.first(where: { !StoredKey.isValidHost($0) }) { throw Failure(StoreError.invalidHost(host)) }
        do {
            if try store.list().contains(where: { $0.name == name }) { throw StoreError.duplicate(name) }
        } catch {
            throw Failure(error)
        }
    }

    /// Stores a new key, tells a running agent, and prints the public key.
    static func finish(_ key: StoredKey, store: KeychainStore, output: JSONOption) throws {
        do { try store.add(key) } catch { throw Failure(error) }
        AgentClient(path: defaultSocketPath).reload()
        if output.json { try output.print(KeySummary(key)) } else { print(KeySummary(key).publicKey) }
    }

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a key and print its public key.")
        @Argument(help: "The key's name: letters, digits, '-', '_' and '.'.") var name: String
        @Option(help: "The key type: a Secure Enclave P-256 key, or an Ed25519 or RSA key wrapped by the Secure Enclave.") var type = KeyType.secureEnclave
        @Option(help: "The comment ssh-add shows; the name when empty.") var comment = ""
        @Option(name: .customLong("host"), help: "An SSH host pattern that uses this key; repeat for more.") var hosts: [String] = []
        @OptionGroup var output: JSONOption

        func run() throws {
            let store = KeychainStore()
            try checkNew(name: name, hosts: hosts, store: store)
            do {
                let key: StoredKey
                if let generated = type.generated {
                    let privateKey = try KeyImport.generate(generated)
                    key = try KeychainStore.makeWrappedKey(name: name, privateKey: privateKey, comment: comment, hosts: hosts, source: "local")
                } else {
                    key = try KeychainStore.makeSecureEnclaveKey(name: name, comment: comment, hosts: hosts)
                }
                try finish(key, store: store, output: output)
            } catch let error as Failure {
                throw error
            } catch {
                throw Failure(error)
            }
        }
    }

    struct Import: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Import a private key file, or stdin with '-', wrapped by the Secure Enclave, and print its public key.",
            discussion: "A passphrase-protected file must be given as a file: ssh-add asks for its passphrase."
        )
        @Argument(help: "The key's name: letters, digits, '-', '_' and '.'.") var name: String
        @Argument(help: "An OpenSSH, PKCS#1, PKCS#8 or SEC1 private key file, or '-' for stdin.") var file: String
        @Option(help: "The comment ssh-add shows; the key's own comment, or the name, when empty.") var comment: String?
        @Option(name: .customLong("host"), help: "An SSH host pattern that uses this key; repeat for more.") var hosts: [String] = []
        @OptionGroup var output: JSONOption

        func run() throws {
            let store = KeychainStore()
            try checkNew(name: name, hosts: hosts, store: store)
            let fromStdin = file == "-"
            guard let data = fromStdin ? FileHandle.standardInput.readDataToEndOfFile() : FileManager.default.contents(atPath: file) else {
                throw Failure("cannot read \(file)")
            }
            do {
                let imported: (PrivateKey, String)
                switch try KeyImport.parse(data) {
                case let .key(key, own):
                    imported = (key, own)
                case .protected:
                    if fromStdin { throw ImportError.protectedOnStdin }
                    imported = try KeyImport.importWithSSHAdd(file: file)
                }
                let key = try KeychainStore.makeWrappedKey(name: name, privateKey: imported.0, comment: comment ?? imported.1, hosts: hosts, source: "import")
                try finish(key, store: store, output: output)
            } catch let error as Failure {
                throw error
            } catch {
                throw Failure(error)
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the stored keys.")
        @OptionGroup var output: JSONOption

        func run() throws {
            let keys = try storedKeys().map(KeySummary.init)
            if output.json { return try output.print(keys) }
            for key in keys {
                let hosts = key.hosts.isEmpty ? "-" : key.hosts.joined(separator: ",")
                print([key.name, key.type, key.algorithm, key.fingerprint, key.source, "hosts=\(hosts)", key.comment].joined(separator: "  "))
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print one key's OpenSSH public key.")
        @Argument var name: String
        @OptionGroup var output: JSONOption

        func run() throws {
            let key = KeySummary(try storedKey(name))
            if output.json { try output.print(key) } else { print(key.publicKey) }
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete one key.")
        @Argument var name: String

        func run() throws {
            do { try KeychainStore().delete(name: name) } catch { throw Failure(error) }
            AgentClient(path: defaultSocketPath).reload()
        }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the agent and its keys; exits non-zero when the agent does not answer.")
    @Option(help: "The agent socket.") var socket = defaultSocketPath
    @OptionGroup var output: JSONOption

    struct Report: Encodable {
        let version: String
        let socket: String
        let agentAnswers: Bool
        let agent: AgentStatus?
        let sync: SyncStatus
    }

    func run() throws {
        let agent = AgentClient(path: socket).status()
        let sync = SyncStatus(signedIn: TokenStore().isStored, state: SyncState.load())
        let report = Report(version: signdVersion, socket: socket, agentAnswers: agent != nil, agent: agent, sync: sync)
        if output.json {
            try output.print(report)
        } else {
            print("signd \(signdVersion)")
            print("socket  \(socket)")
            if let agent {
                print("agent   answers (pid \(agent.pid), \(agent.version))")
                if let error = agent.storeError { print("store   \(error)") }
                for key in agent.keys { print("key     \(key.name)  \(key.inMemory ? "in memory" : "not in memory")") }
                if agent.memoryOnlyKeys > 0 { print("memory-only keys  \(agent.memoryOnlyKeys)") }
            } else {
                print("agent   does not answer")
            }
            print(sync.signedIn ? "1password  signed in" : "1password  not signed in; run signd login")
            print("interval  \(sync.interval.value) (\(sync.interval.source.rawValue))")
            if let at = sync.lastCheck, let result = sync.lastResult {
                let detail = sync.lastMessage.map { ": \($0)" } ?? ""
                print("last check  \(at.formatted(.iso8601)) \(result.rawValue)\(detail), \(sync.requests) requests, \(sync.fetched) items fetched")
            }
            if let next = sync.nextAttempt { print("next attempt  \(next.formatted(.iso8601))") }
            for item in sync.skipped { print("skipped  \(item.item): \(item.reason)") }
        }
        if agent == nil { throw ExitCode.failure }
    }
}

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Store a 1Password service account token read from stdin, so signd syncs keys from 1Password.",
        discussion: "The token is read from stdin only, never from an argument or the environment; a token stored before stays when 1Password refuses the new one."
    )

    func run() async throws {
        guard isatty(STDIN_FILENO) == 0 else { throw Failure("pipe the token into stdin") }
        let token = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw Failure("stdin holds no token") }
        let vaults: [VaultOverview]
        do throws(OnePasswordError) {
            vaults = try await Client(token: token, integrationName: "signd", integrationVersion: signdVersion).vaults()
        } catch {
            throw Failure(error.kind == .authentication ? "1Password refused the token: \(error.message)" : "cannot read from 1Password: \(error.message)")
        }
        do { try TokenStore().write(token) } catch { throw Failure(error) }
        SyncState.remove()
        AgentClient(path: defaultSocketPath).reload()
        print("signed in; the token reads \(vaults.count) vault\(vaults.count == 1 ? "" : "s")")
    }
}

struct Logout: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete the stored token and every key synced from 1Password; local keys stay.")

    func run() throws {
        let store = KeychainStore()
        let synced = try storedKeys().filter(\.isSynced)
        do {
            for key in synced { try store.delete(name: key.name) }
            try TokenStore().delete()
        } catch {
            throw Failure(error)
        }
        SyncState.remove()
        AgentClient(path: defaultSocketPath).reload()
        print("signed out; removed \(synced.count) synced key\(synced.count == 1 ? "" : "s")")
    }
}

struct SyncNow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync", abstract: "Check 1Password now, wait for the result, and report what changed.")
    @Option(help: "The agent socket.") var socket = defaultSocketPath
    @OptionGroup var output: JSONOption

    func run() throws {
        guard let summary = AgentClient(path: socket).sync() else { throw Failure("the agent does not answer") }
        if output.json {
            try output.print(summary)
        } else {
            print("\(summary.outcome.rawValue): \(summary.requests) requests, \(summary.fetched) items fetched")
            if let message = summary.message { print(message) }
            for name in summary.added { print("added  \(name)") }
            for name in summary.replaced { print("replaced  \(name)") }
            for name in summary.removed { print("removed  \(name)") }
            if summary.skipped > 0 { print("skipped  \(summary.skipped); see signd status") }
        }
        if summary.outcome != .ok { throw ExitCode.failure }
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Read and change settings.", subcommands: [Get.self, Set.self, Unset.self])

    struct SettingName: ExpressibleByArgument {
        let key: Settings.Key
        init?(argument: String) {
            guard let key = Settings.Key(rawValue: argument) else { return nil }
            self.key = key
        }

        static var allValueStrings: [String] { Settings.Key.allCases.map(\.rawValue) }
    }

    struct Get: ParsableCommand {
        @Argument var name: SettingName
        func run() {
            print(Settings().resolve(name.key, fleet: SyncState.load().fleet).value)
        }
    }

    struct Set: ParsableCommand {
        @Argument var name: SettingName
        @Argument var value: String
        func run() throws {
            do { try Settings().set(name.key, value) } catch { throw Failure(error) }
        }
    }

    struct Unset: ParsableCommand {
        @Argument var name: SettingName
        func run() {
            Settings().unset(name.key)
        }
    }
}

struct Service: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the agent at login, or stop doing so.", subcommands: [Enable.self, Disable.self])
    static var agent: SMAppService { .agent(plistName: "com.victor-software-house.signd.plist") }

    struct Enable: ParsableCommand {
        func run() throws {
            switch Service.agent.status {
            case .enabled where Self.agentAnswers():
                print("enabled")
            case .enabled:
                // The cask's uninstall step, which an upgrade also runs, removes the job from
                // launchd while the login item stays enabled; registering again restores it.
                do {
                    try Service.agent.unregister()
                    try Service.agent.register()
                } catch {
                    throw Failure("cannot register the agent again: \(error)")
                }
                print("enabled")
            case .requiresApproval:
                throw Failure("approve signd in System Settings, General, Login Items")
            default:
                do { try Service.agent.register() } catch { throw Failure("cannot register the agent: \(error)") }
                print(Service.agent.status == .enabled ? "enabled" : "registered; approve signd in System Settings, General, Login Items")
            }
        }

        /// Whether the agent answers within two seconds, which covers one that launchd is starting.
        static func agentAnswers() -> Bool {
            for _ in 0 ..< 20 {
                if AgentClient(path: defaultSocketPath).status() != nil { return true }
                usleep(100_000)
            }
            return false
        }
    }

    struct Disable: ParsableCommand {
        func run() throws {
            guard Service.agent.status != .notRegistered else { return print("not registered") }
            do { try Service.agent.unregister() } catch { throw Failure("cannot unregister the agent: \(error)") }
            print("disabled")
        }
    }
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the agent in the foreground.")
    @Option(help: "The socket to listen on.") var socket = defaultSocketPath

    func run() async throws {
        signal(SIGPIPE, SIG_IGN)
        let settings = Settings()
        let store = KeychainStore()
        let fleet = FleetSettings()
        let socketPath = socket
        let routingLog = Logger(subsystem: "com.victor-software-house.signd", category: "routing")
        let agent = Agent(
            store: store, version: signdVersion, lifetime: { settings.resolve(.keyLifetime, fleet: fleet.values).seconds },
            keysRead: { keys in
                do {
                    try Routing.write(keys, socket: socketPath)
                } catch {
                    routingLog.error("cannot write the SSH routing files: \(String(describing: error), privacy: .public)")
                }
            }
        )
        let sync = SyncService(
            SyncService.Dependencies(
                token: { () throws(StoreError) -> String? in try TokenStore().read() }, makeSource: LiveSource.factory(version: signdVersion), store: store, wrap: LiveSource.wrapper,
                interval: { settings.resolve(.interval, fleet: $0).seconds }, changed: { await agent.reload() }
            ),
            fleet: fleet
        )
        try await Server(agent: agent, sync: sync).run(socketPath: socket)
    }
}
