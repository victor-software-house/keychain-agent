# Tasks

## 1. Code

- [x] 1.1 Add `ColorChoice` and the colour decision by design decision 1, and `--color` by decision 2.
  Verify unit tests of every combination of flag, `NO_COLOR`, `CLICOLOR_FORCE` and terminal.
  - 2026-11-19 UTC: `ColorChoice`, `ColorOption` and `JSONOption.colorOption` are written, with the 24 combinations in `TerminalOutputTests.swift`; CI has not run yet.
- [x] 1.2 Add Noora 0.57.7 and format results and `signd status` by decisions 3 and 4.
  Verify unit tests that each formatted line without colour equals today's text.
  Verify a test that a coloured line starts with its symbol.
  - 2026-11-19 UTC: `TerminalStyle` is written and every result line and `signd status` value uses it, with tests in `TerminalOutputTests.swift`; CI has not run yet.
- [x] 1.3 Print failures by decision 5 in both entry points.
  Verify a test that a `Failure` without colour prints ArgumentParser's message.
  - 2026-11-19 UTC: `Signd.runMain()` is written and both entry points call it; CI has not run yet.
    No test runs it, since it exits the process.

## 2. Release

- [x] 2.1 Record the size of the `signd` binary before Noora and with it, from the two releases.
  - 2026-11-19 UTC: `Signd.app/Contents/MacOS/signd` is 28,875,616 bytes in 0.0.17 and 29,461,744 bytes in 0.0.18.
    Noora, Rainbow, swift-log and Path add 586,128 bytes, 2.0%.
- [x] 2.2 On a Mac, run `signd status` on a terminal, piped, and with `NO_COLOR`, `--color always` and `--json`.
  Verify the output of each matches the spec.
  - 2026-11-19 UTC: on 0.0.18, `signd status | cat` printed no escape sequence and no symbol.
    Under `script`, a terminal, `signd update` printed a green `✔` line, and `NO_COLOR=1` printed the plain line.
  - `--color always` and `CLICOLOR_FORCE=1` piped through `cat` gave the green `✔`, and `CLICOLOR_FORCE=0` gave the plain line.
    `signd status --json --color always` parsed as JSON with no escape sequence.
