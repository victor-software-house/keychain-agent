# Proposal

## Why

On a terminal, signd prints every result as plain text, so a failed check and a passed one look the same.
The operator picked Noora 0.57.7 for terminal output, to match the other command-line tools (operator, 2026-11-18).

## What Changes

- On a terminal, signd marks each result: `✔` and green for a success, `✘` and red for a failure, `▲` and yellow for a warning.
  `signd status` colours each value by its state.
- Piped output, and output under `NO_COLOR` or `--color never`, stays byte for byte what it is today, so scripts read the same text.
- `CLICOLOR_FORCE` and `--color always` force colour, and `--color auto` is the default.
- `--json` output is never coloured.
- The agent and the updater daemon print nothing through Noora, and neither installs Noora's signal handlers.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `cli`: terminal output and the `--color` option.

## Impact

- The package gains Noora 0.57.7 and the packages it uses: Rainbow, swift-log and Path.
- The pull request records the size of the `signd` binary before and after.
- No setting, stored format or message between the command line and the agent changes.
