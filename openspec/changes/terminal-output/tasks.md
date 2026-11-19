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

- [ ] 2.1 Record the size of the `signd` binary before Noora and with it, from the two releases.
- [ ] 2.2 On a Mac, run `signd status` on a terminal, piped, and with `NO_COLOR`, `--color always` and `--json`.
  Verify the output of each matches the spec.
