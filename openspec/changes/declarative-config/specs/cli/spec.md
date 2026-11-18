# cli

## ADDED Requirements

### Requirement: `signd plan` shows an apply before it runs

`signd plan` SHALL print each step an apply would take and SHALL make none of them.
It SHALL exit 0 when there is no step and non-zero otherwise.

#### Scenario: A new entry

- **WHEN** the file declares a key that does not exist
- **THEN** `signd plan` prints a create step for it, exits non-zero, and `signd key list` still lacks it

### Requirement: `signd config set` writes the file

`signd config set` SHALL rewrite `~/.config/signd/config.toml` in one rename, only when the new text loads, and SHALL reject a setting the profile manages.

#### Scenario: A managed setting

- **WHEN** a profile sets `interval` and `signd config set interval 10m` runs
- **THEN** the command fails, shows the profile, and the file is unchanged
