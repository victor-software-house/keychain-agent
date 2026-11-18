# cli

## ADDED Requirements

### Requirement: Status shows the install

`signd status` SHALL print the login item's state and whether `~/.ssh/config` includes signd's file, and SHALL name `signd service enable` on each line that is not in order; `--json` SHALL carry both.

#### Scenario: Approval pending

- **WHEN** the login item needs approval
- **THEN** `signd status` shows the pending approval and names `signd service enable`

### Requirement: service enable opens Login Items

When the login item needs approval, `signd service enable` SHALL open System Settings at Login Items and exit non-zero.

#### Scenario: Approval pending

- **WHEN** the login item needs approval and `signd service enable` runs
- **THEN** System Settings opens at Login Items and the command exits non-zero
