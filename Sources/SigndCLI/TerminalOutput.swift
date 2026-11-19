import ArgumentParser
import Darwin
import Foundation
import Noora
@preconcurrency import Rainbow
import Synchronization

/// When a stream gets colour: `--color auto|always|never`.
enum ColorChoice: String, ExpressibleByArgument, CaseIterable, Sendable {
    case auto
    case always
    case never

    /// The choice `--color` gave in this process, `auto` before any command line is validated.
    private static let recorded = Mutex(ColorChoice.auto)

    static var current: ColorChoice { recorded.withLock { $0 } }

    static func record(_ choice: ColorChoice) {
        recorded.withLock { $0 = choice }
    }

    /// Whether a stream gets colour.
    /// The flag wins over the environment; `auto` lets `NO_COLOR` win over `CLICOLOR_FORCE`, and both win over the terminal check.
    func isColored(environment: [String: String], isTerminal: Bool) -> Bool {
        switch self {
        case .never: return false
        case .always: return true
        case .auto:
            if environment["NO_COLOR"] != nil { return false }
            if environment["CLICOLOR_FORCE"] != nil { return true }
            return isTerminal
        }
    }
}

/// The `--color` option of a command that prints a result.
struct ColorOption: ParsableArguments {
    @Option(help: "When to colour the output: auto, always or never.")
    var color: ColorChoice = .auto

    mutating func validate() throws {
        ColorChoice.record(color)
    }

    var standardOutput: TerminalStyle { TerminalStyle(.standardOutput, choice: color) }
}

enum StandardStream {
    case standardOutput
    case standardError

    var descriptor: Int32 {
        switch self {
        case .standardOutput: STDOUT_FILENO
        case .standardError: STDERR_FILENO
        }
    }
}

/// How one stream prints a result.
/// Without colour, each method returns its text as it is.
/// With colour, it returns the text coloured by Noora, and a result gets its symbol in front.
struct TerminalStyle: Sendable {
    /// The state a value of `signd status` shows.
    enum Level {
        case inOrder
        case failed
        case waiting
    }

    private let noora: Noora?

    var isColored: Bool { noora != nil }

    init(_ stream: StandardStream, choice: ColorChoice, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(isColored: choice.isColored(environment: environment, isTerminal: isatty(stream.descriptor) != 0))
    }

    init(isColored: Bool) {
        guard isColored else {
            noora = nil
            return
        }
        _ = Self.rainbow
        // Noora installs signal handlers unless told not to, and the command line needs none.
        noora = Noora(theme: .signd, terminal: Terminal(isInteractive: false, isColored: true, signalBehavior: .none))
    }

    /// Rainbow prints plain text unless stdout is a terminal and `TERM` is set, so the first coloured stream turns it on for both.
    private static let rainbow: Void = {
        Rainbow.enabled = true
        Rainbow.outputTarget = .console
    }()

    func success(_ text: String) -> String { mark("✔ \(text)", TerminalText.Component.success) }

    func failure(_ text: String) -> String { mark("✘ \(text)", TerminalText.Component.danger) }

    func warning(_ text: String) -> String { mark("▲ \(text)", TerminalText.Component.accent) }

    /// A value of `signd status`, coloured by its state and with no symbol; a value with no state stays plain.
    func value(_ text: String, _ level: Level?) -> String {
        switch level {
        case .inOrder?: mark(text, TerminalText.Component.success)
        case .failed?: mark(text, TerminalText.Component.danger)
        case .waiting?: mark(text, TerminalText.Component.accent)
        case nil: text
        }
    }

    private func mark(_ text: String, _ component: (String) -> TerminalText.Component) -> String {
        guard let noora else { return text }
        let terminalText: TerminalText = "\(component(text))"
        return noora.format(terminalText)
    }
}

extension Theme {
    /// Noora's default theme with a yellow accent for the warnings, since the default accent is orange.
    static let signd = Theme(
        primary: "A378F2",
        secondary: "FF4081",
        muted: "505050",
        accent: "E5B800",
        danger: "FF2929",
        success: "56822B",
        info: "0280B9",
        selectedRowText: "FFFFFF",
        selectedRowBackground: "4600AE"
    )
}

extension Signd {
    /// Runs the command line as `Signd.main()` does, except that a failure on a stderr with colour prints `✘ reason` in red.
    /// Every other error keeps ArgumentParser's message.
    /// The agent, the updater daemon and the postinstall step never print through Noora.
    public static func runMain() {
        var printsThroughNoora = true
        do {
            var command = try parseAsRoot()
            printsThroughNoora = !(command is Serve || command is UpdaterDaemon || command is Postinstall)
            try command.run()
        } catch {
            if printsThroughNoora, let failure = error as? Failure {
                let style = TerminalStyle(.standardError, choice: .current)
                if style.isColored {
                    FileHandle.standardError.write(Data("\(style.failure(failure.description))\n".utf8))
                    Darwin.exit(exitCode(for: error).rawValue)
                }
            }
            exit(withError: error)
        }
    }
}
