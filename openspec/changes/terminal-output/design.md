# Design

## Context

Every command prints through `Swift.print` and `FileHandle.standardError`.
`JSONOption.print` writes the JSON documents.
`KeyCommand.note` writes a warning to stderr with a `▲` already.
Both entry points, `Sources/signd/main.swift` and `App/main.swift`, call `Signd.main()`, and ArgumentParser prints a failure as `Error: reason`.

Noora's `Terminal` reads `NO_COLOR` and `CLICOLOR_FORCE`, and checks whether stdout is a terminal.
Its initializer also installs signal handlers that call `exit(0)` on an interrupt, a termination or a hangup, unless `signalBehavior` is `.none`.

## Decisions

### 1. One colour decision, made once per command

A value type `ColorChoice` (`auto`, `always`, `never`) and a function decide whether a stream gets colour.
The inputs are the choice, the environment and whether the stream is a terminal.

`never` and `NO_COLOR` turn colour off.
`always` and `CLICOLOR_FORCE` turn it on, and `auto` follows the terminal check.
A flag wins over the environment.
The function is pure, so a test covers each case with no terminal.

### 2. A `--color` option beside `--json`

`JSONOption` gains `--color auto|always|never`, so each command that already takes `--json` takes `--color` too.
A command that prints a result and has no `JSONOption` takes the option on its own.
`--json` output goes through `JSONOption.print` unchanged and never gets colour.

### 3. Noora only formats

The command line builds one `Noora` with `Terminal(isInteractive: false, isColored: decision, signalBehavior: .none)`.
It uses Noora's `TerminalText` and `format` to colour a line, and prints the line itself.
It never uses Noora's prompts, steps or tables.
`signd serve` and the updater daemon never build a `Noora`, so their signal handling stays their own.

Noora colours text through Rainbow, which emits plain text unless stdout is a terminal and `TERM` is set.
So when either stream gets colour, the command line sets `Rainbow.enabled` and `Rainbow.outputTarget = .console` once, before it prints.
Each stream's `Noora` still decides by its own `isColored`.

### 4. Plain text without colour

With colour off, each line is the same text as today, with no symbol added.
With colour on, a result line gets its symbol in front, and `signd status` colours each value by its state.
The backup and update lines of `signd status`, which their own modules build, stay plain in this change.

| State | Colour | Examples |
|:--|:--|:--|
| In order | green | `answers`, `enabled`, `ok` |
| Failed | red | `does not answer`, `failed` |
| Waiting | yellow | `waiting`, `skipped` |

### 5. Failures

The entry points catch the command's error.
For a `Failure` on a stderr that gets colour, they print `✘ reason` in red, then exit with ArgumentParser's exit code.
For any other error, or with colour off, they leave ArgumentParser's own message.

## Risks

- A static Noora adds Rainbow, swift-log and Path to the binary; the pull request measures the size.
- A new line that skips the formatter stays plain, which is safe.
