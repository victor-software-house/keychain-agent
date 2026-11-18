# cli

## ADDED Requirements

### Requirement: backup commands

`signd backup login` SHALL read a service account token from stdin, check that it can write to the backup vault, and store it.
`signd backup logout` SHALL delete the token on every Mac.
`signd backup run` SHALL start a run at once, and `signd backup status` SHALL print the vault, the last run, its result and the next slot.

#### Scenario: A token on the command line

- **WHEN** `signd backup login` runs with a token as an argument
- **THEN** the command exits non-zero with an error that names stdin, and stores nothing

### Requirement: Status shows the backup

`signd status` SHALL show whether the backup is on, the time and result of its last run, and its next slot; `--json` SHALL carry the same.

#### Scenario: No token

- **WHEN** no token is stored
- **THEN** `signd status` shows the backup as off and names `signd backup login`
