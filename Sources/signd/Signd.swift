import AgentServer
import AppKit
import ArgumentParser
import CloudKit
import Foundation
import KeyStore
import os
import ServiceManagement
import SSHWire
import Sync
import SystemConfiguration

@main
struct Signd: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "An SSH agent for keys only its signed app can use, shared through iCloud.",
        version: signdVersion,
        subcommands: [KeyCommand.self, DeviceCommand.self, SyncNow.self, Status.self, Config.self, Service.self, Serve.self, Postinstall.self]
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
    static let configuration = CommandConfiguration(commandName: "key", abstract: "Create, list, show and delete keys.", subcommands: [Create.self, Import.self, Share.self, List.self, Show.self, Delete.self])

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

    /// Stores a new key, tells a running agent, shares it unless `local`, and prints the public key.
    static func finish(_ key: StoredKey, store: KeychainStore, local: Bool, output: JSONOption) throws {
        do { try store.add(key) } catch { throw Failure(error) }
        let client = AgentClient(path: defaultSocketPath)
        client.reload()
        var printed = key
        var failure: Failure?
        if !local && key.kind == .wrapped {
            switch client.share(key.name) {
            case nil:
                failure = Failure("created \(key.name) on this Mac, but the agent does not answer, so it is not shared; run signd key share \(key.name)")
            case let result? where result.outcome == .failed:
                failure = Failure("created \(key.name) on this Mac, but did not share it: \(result.message ?? "unknown reason"); run signd key share \(key.name)")
            case let result? where result.outcome == .off:
                note(result.message ?? "sync is off; \(key.name) stays on this Mac")
            case _:
                printed = (try? storedKey(key.name)) ?? key
            }
        }
        if output.json { try output.print(KeySummary(printed)) } else { print(KeySummary(printed).publicKey) }
        if let failure { throw failure }
    }

    /// Writes a note to stderr, so stdout keeps only the command's output.
    static func note(_ text: String) {
        FileHandle.standardError.write(Data("▲ \(text)\n".utf8))
    }

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a key and print its public key.")
        @Argument(help: "The key's name: letters, digits, '-', '_' and '.'.") var name: String
        @Option(help: "The key type: a Secure Enclave P-256 key, or an Ed25519 or RSA key wrapped by the Secure Enclave.") var type = KeyType.secureEnclave
        @Option(help: "The comment ssh-add shows; the name when empty.") var comment = ""
        @Option(name: .customLong("host"), help: "An SSH host pattern that uses this key; repeat for more.") var hosts: [String] = []
        @Flag(help: "Keep the key on this Mac instead of sharing it through iCloud. A Secure Enclave key always stays.") var local = false
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
                try finish(key, store: store, local: local, output: output)
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
        @Flag(help: "Keep the key on this Mac instead of sharing it through iCloud.") var local = false
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
                try finish(key, store: store, local: local, output: output)
            } catch let error as Failure {
                throw error
            } catch {
                throw Failure(error)
            }
        }
    }

    struct Share: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Share a key of this Mac with every device on the iCloud account.")
        @Argument var name: String

        func run() throws {
            guard let result = AgentClient(path: defaultSocketPath).share(name) else { throw Failure("the agent does not answer") }
            switch result.outcome {
            case .done: print("shared \(name)")
            case .off: throw Failure(result.message ?? "sync is off")
            case .failed: throw Failure(result.message ?? "the share failed")
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
        static let configuration = CommandConfiguration(abstract: "Delete one key; a shared key is deleted on every device.")
        @Argument var name: String

        func run() throws {
            let key = try storedKey(name)
            let client = AgentClient(path: defaultSocketPath)
            if key.isShared {
                guard let result = client.deleteShared(name) else { throw Failure("the agent does not answer, and a shared key is deleted through it") }
                guard result.outcome == .done else { throw Failure(result.message ?? "the delete failed") }
                return
            }
            do { try KeychainStore().delete(name: name) } catch { throw Failure(error) }
            client.reload()
        }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the agent, its keys and the iCloud sync; exits non-zero when the agent does not answer.")
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
        let client = AgentClient(path: socket)
        let agent = client.status()
        let sync = SyncStatus(state: client.syncState() ?? SyncState.load())
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
            print("icloud  \(sync.state)\(sync.lastMessage.map { ": \($0)" } ?? "")")
            print("interval  \(sync.interval.value) (\(sync.interval.source.rawValue))")
            if let at = sync.lastCheck, let result = sync.lastResult {
                print("last check  \(at.formatted(.iso8601)) \(result.rawValue), \(sync.requests) requests")
            }
            if let next = sync.nextAttempt { print("next check  \(next.formatted(.iso8601))") }
            if let push = sync.lastPush { print("last push  \(push.formatted(.iso8601))") }
            print("devices  \(sync.devices)")
            for setting in sync.ignoredSettings { print("ignored  \(setting.key) \(setting.value) (local): \(setting.reason)") }
            for key in sync.skipped { print("\(key.kind == .waiting ? "waiting" : "skipped")  \(key.name): \(key.reason)") }
        }
        if agent == nil { throw ExitCode.failure }
    }
}

struct DeviceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "device", abstract: "List and remove the devices that share keys through iCloud.", subcommands: [List.self, Remove.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the devices on the iCloud account.")
        @OptionGroup var output: JSONOption

        func run() throws {
            guard let devices = AgentClient(path: defaultSocketPath).devices() else { throw Failure("the agent does not answer") }
            if output.json { return try output.print(devices) }
            for device in devices { print([device.name, device.id, device.isThisDevice ? "this device" : ""].joined(separator: "  ")) }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a device that no longer runs signd, and drop its copies of every shared key.",
            discussion: "A removal that fails partway, or that runs while another Mac checks iCloud, may leave a copy. Run it again to drop it."
        )
        @Argument(help: "The device's id, as signd device list prints it.") var id: String

        func run() throws {
            guard let result = AgentClient(path: defaultSocketPath).removeDevice(id) else { throw Failure("the agent does not answer") }
            guard result.outcome == .done else { throw Failure(result.message ?? "the removal failed") }
            print("removed \(id)")
        }
    }
}

struct SyncNow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync", abstract: "Check iCloud now, wait for the result, and report what changed.")
    @Option(help: "The agent socket.") var socket = defaultSocketPath
    @OptionGroup var output: JSONOption

    func run() throws {
        guard let summary = AgentClient(path: socket).sync() else { throw Failure("the agent does not answer") }
        if output.json {
            try output.print(summary)
        } else {
            print("\(summary.outcome.rawValue): \(summary.requests) requests")
            if let message = summary.message { print(message) }
            for name in summary.added { print("added  \(name)") }
            for name in summary.replaced { print("replaced  \(name)") }
            for name in summary.removed { print("removed  \(name)") }
            for name in summary.sealed { print("shared with a new device  \(name)") }
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
            print(Settings().resolve(name.key).value)
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
                // The cask's uninstall step removes the job from launchd while the login item stays enabled.
                // An upgrade also runs that step, and registering again restores the job.
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

struct Serve: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the agent in the foreground.")
    @Option(help: "The socket to listen on.") var socket = defaultSocketPath

    func run() throws {
        signal(SIGPIPE, SIG_IGN)
        let settings = Settings()
        let store = KeychainStore()
        let socketPath = socket
        let log = Logger(subsystem: "com.victor-software-house.signd", category: "agent")
        let agent = Agent(
            store: store, version: signdVersion, lifetime: { settings.resolve(.keyLifetime).seconds },
            keysRead: { keys in
                do {
                    try Routing.write(keys, socket: socketPath, home: FileManager.default.homeDirectoryForCurrentUser)
                } catch {
                    log.error("cannot write the SSH routing files: \(String(describing: error), privacy: .public)")
                }
            }
        )
        // A build without an iCloud container in its signature never touches CloudKit, which would stop the process.
        let cloud: (any CloudStore)? = CloudContainer.signed.map { CloudKitStore(containerID: $0) }
        let sync = SyncService(
            SyncService.Dependencies(
                cloud: cloud, store: store, device: { () throws(StoreError) -> DeviceKey in try DeviceKeyStore().readOrCreate() },
                open: { key throws(SignError) in try Wrapping.openStored(key) }, version: signdVersion,
                interval: { settings.resolve(.interval).seconds }, changed: { await agent.reload() }
            )
        )
        let server = Server(agent: agent, sync: sync)
        Task.detached {
            do {
                try await server.run(socketPath: socketPath)
            } catch {
                log.fault("the agent stopped: \(String(describing: error), privacy: .public)")
                Darwin.exit(1)
            }
        }
        guard cloud != nil else { dispatchMain() }
        // Pushes reach only a running application, so the agent runs one, with no window and no Dock icon.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let receiver = PushReceiver(sync: sync)
            app.delegate = receiver
            NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { _ in sync.accountChanged() }
            withExtendedLifetime(receiver) { app.run() }
        }
    }
}

/// The package's postinstall step runs as root.
/// It starts the agent again as the user at the console.
/// A cask upgrade first removes the agent's job from launchd, so `service enable` registers the login item again.
/// With nobody logged in, the login item starts the agent at the next login. It never fails the install.
struct Postinstall: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start the agent as the console user after the package installs.", shouldDisplay: false)

    func run() {
        let log = Logger(subsystem: "com.victor-software-house.signd", category: "install")
        var uid: uid_t = 0
        guard let user = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?, uid != 0, user != "loginwindow" else { return }
        let signd = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["asuser", String(uid), "/usr/bin/sudo", "-u", user, signd, "service", "enable"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.error("cannot start the agent for \(user, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
