import Foundation
import Testing
@testable import SigndCLI

private struct ColorCase: CustomTestStringConvertible, Sendable {
    let choice: ColorChoice
    let noColor: Bool
    let force: Bool
    let terminal: Bool
    let expected: Bool

    var testDescription: String { "\(choice) NO_COLOR=\(noColor) CLICOLOR_FORCE=\(force) terminal=\(terminal)" }

    var environment: [String: String] {
        var environment: [String: String] = [:]
        if noColor { environment["NO_COLOR"] = "1" }
        if force { environment["CLICOLOR_FORCE"] = "1" }
        return environment
    }
}

private let colorCases = [
    ColorCase(choice: .auto, noColor: false, force: false, terminal: false, expected: false),
    ColorCase(choice: .auto, noColor: false, force: false, terminal: true, expected: true),
    ColorCase(choice: .auto, noColor: false, force: true, terminal: false, expected: true),
    ColorCase(choice: .auto, noColor: false, force: true, terminal: true, expected: true),
    ColorCase(choice: .auto, noColor: true, force: false, terminal: false, expected: false),
    ColorCase(choice: .auto, noColor: true, force: false, terminal: true, expected: false),
    ColorCase(choice: .auto, noColor: true, force: true, terminal: false, expected: false),
    ColorCase(choice: .auto, noColor: true, force: true, terminal: true, expected: false),
    ColorCase(choice: .always, noColor: false, force: false, terminal: false, expected: true),
    ColorCase(choice: .always, noColor: false, force: false, terminal: true, expected: true),
    ColorCase(choice: .always, noColor: false, force: true, terminal: false, expected: true),
    ColorCase(choice: .always, noColor: false, force: true, terminal: true, expected: true),
    ColorCase(choice: .always, noColor: true, force: false, terminal: false, expected: true),
    ColorCase(choice: .always, noColor: true, force: false, terminal: true, expected: true),
    ColorCase(choice: .always, noColor: true, force: true, terminal: false, expected: true),
    ColorCase(choice: .always, noColor: true, force: true, terminal: true, expected: true),
    ColorCase(choice: .never, noColor: false, force: false, terminal: false, expected: false),
    ColorCase(choice: .never, noColor: false, force: false, terminal: true, expected: false),
    ColorCase(choice: .never, noColor: false, force: true, terminal: false, expected: false),
    ColorCase(choice: .never, noColor: false, force: true, terminal: true, expected: false),
    ColorCase(choice: .never, noColor: true, force: false, terminal: false, expected: false),
    ColorCase(choice: .never, noColor: true, force: false, terminal: true, expected: false),
    ColorCase(choice: .never, noColor: true, force: true, terminal: false, expected: false),
    ColorCase(choice: .never, noColor: true, force: true, terminal: true, expected: false),
]

@Test(arguments: colorCases)
fileprivate func theColourFollowsTheFlagThenTheEnvironmentThenTheTerminal(_ test: ColorCase) {
    #expect(test.choice.isColored(environment: test.environment, isTerminal: test.terminal) == test.expected)
}

@Test func aLineWithoutColourIsTheTextAsItIs() {
    let style = TerminalStyle(isColored: false)
    #expect(!style.isColored)
    #expect(style.success("enabled") == "enabled")
    #expect(style.failure("the agent does not answer") == "the agent does not answer")
    #expect(style.warning("not registered") == "not registered")
    #expect(style.value("answers (pid 1, 0.0.0)", .inOrder) == "answers (pid 1, 0.0.0)")
    #expect(style.value("does not answer", .failed) == "does not answer")
    #expect(style.value("waiting", .waiting) == "waiting")
    #expect(style.value("on", nil) == "on")
}

@Test func aSuccessWithColourStartsWithItsSymbolAfterTheEscapeSequence() throws {
    let line = TerminalStyle(isColored: true).success("enabled")
    #expect(line.contains("\u{1B}["))
    let symbol = try #require(line.range(of: "✔"))
    let text = try #require(line.range(of: "enabled"))
    #expect(symbol.upperBound <= text.lowerBound)
}

@Test func aFailureAndAWarningWithColourCarryTheirSymbols() throws {
    let style = TerminalStyle(isColored: true)
    let failure = style.failure("the agent does not answer")
    #expect(failure.contains("\u{1B}["))
    let failureSymbol = try #require(failure.range(of: "✘"))
    let failureText = try #require(failure.range(of: "the agent"))
    #expect(failureSymbol.upperBound <= failureText.lowerBound)
    let warning = style.warning("not registered")
    #expect(warning.contains("\u{1B}["))
    let warningSymbol = try #require(warning.range(of: "▲"))
    let warningText = try #require(warning.range(of: "not registered"))
    #expect(warningSymbol.upperBound <= warningText.lowerBound)
}

@Test func aValueWithColourHasNoSymbolAndAValueWithNoStateStaysPlain() {
    let style = TerminalStyle(isColored: true)
    for level in [TerminalStyle.Level.inOrder, .failed, .waiting] {
        let value = style.value("answers", level)
        #expect(value.contains("\u{1B}["))
        #expect(value.contains("answers"))
        #expect(!value.contains("✔") && !value.contains("✘") && !value.contains("▲"))
    }
    #expect(style.value("on", nil) == "on")
}
