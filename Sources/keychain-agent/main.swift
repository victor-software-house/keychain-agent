// keychain-agent: an SSH agent that signs with RSA keys held non-extractable in the
// login keychain. Usage:
//
//   keychain-agent [--socket PATH] LABEL...
//
// launchd starts it on the first connection to the socket its LaunchAgent declares
// under Sockets → Listeners; --socket binds PATH instead, for tests. It exits after
// two minutes with no client. Each LABEL is the keychain label of a key it serves.
import Darwin
import Foundation

func logError(_ text: String) {
    FileHandle.standardError.write(Data("keychain-agent: \(text)\n".utf8))
}

/// The command line: the labels, and an optional socket path.
struct Arguments {
    var socketPath: String?
    var labels: [String] = []

    init(_ arguments: ArraySlice<String>) throws(UsageError) {
        var rest = arguments
        while let argument = rest.popFirst() {
            switch argument {
            case "--socket":
                guard let path = rest.popFirst() else { throw UsageError(message: "--socket needs a path") }
                socketPath = path
            case "--version":
                throw UsageError(message: nil)
            default:
                labels.append(argument)
            }
        }
        if labels.isEmpty { throw UsageError(message: "name at least one keychain label") }
    }
}

struct UsageError: Error {
    /// nil asks for the version.
    let message: String?
}

let arguments: Arguments
do throws(UsageError) {
    arguments = try Arguments(CommandLine.arguments.dropFirst())
} catch {
    guard let message = error.message else {
        print("keychain-agent \(agentVersion)")
        exit(0)
    }
    logError("\(message)\nusage: keychain-agent [--socket PATH] LABEL...")
    exit(64)
}

// A client that closes early must not end the agent through SIGPIPE.
signal(SIGPIPE, SIG_IGN)

let listeners: [Int32]
do throws(Listener.SetupError) {
    if let path = arguments.socketPath {
        listeners = [try Listener.bound(at: path)]
    } else {
        listeners = try Listener.activated()
    }
} catch {
    logError(error.description)
    exit(1)
}
serve(listeners, labels: arguments.labels, idleSeconds: 120)
