# cli

## ADDED Requirements

### Requirement: Terminal output

On a stream that gets colour, signd SHALL mark a success with a green `✔`, a failure with a red `✘` and a warning with a yellow `▲`.
`signd status` SHALL colour each value by its state.

A stream gets colour when it is a terminal, unless `NO_COLOR` is set or `--color never` is given.
`CLICOLOR_FORCE` and `--color always` SHALL give it colour.
`--json` output SHALL never get colour.
Without colour, every line SHALL be the text signd printed before this change.

#### Scenario: Piped status

- **WHEN** `signd status | cat` runs
- **THEN** the output has no escape sequence and no symbol that the same command did not print before

#### Scenario: Forced colour

- **WHEN** `CLICOLOR_FORCE=1 signd update | cat` runs and signd is up to date
- **THEN** the line starts with a green `✔`

#### Scenario: JSON stays plain

- **WHEN** `signd status --json --color always` runs
- **THEN** stdout parses as JSON and has no escape sequence
