# cli

## ADDED Requirements

### Requirement: Status shows the install

`signd status` SHALL print the login item's state and whether `~/.ssh/config` includes signd's file, and SHALL name `signd service enable` on each line that is not in order; `--json` SHALL carry both.

#### Scenario: Approval pending

- **WHEN** the login item needs approval
- **THEN** `signd status` shows the pending approval and names `signd service enable`

### Requirement: service reports and controls the agent

`signd service status` SHALL print the login item's state and whether the agent answers, with its version.
`signd service restart` SHALL restart the agent and SHALL exit non-zero when it does not answer within 5 seconds.
`signd service log` SHALL print the agent's log entries of the last hour, and SHALL follow new entries with `--follow`.

#### Scenario: A restart

- **WHEN** the agent runs and `signd service restart` runs
- **THEN** the agent answers with a new process identifier, and the command exits zero

### Requirement: service enable opens Login Items

When the login item needs approval, `signd service enable` SHALL open System Settings at Login Items and exit non-zero.

#### Scenario: Approval pending

- **WHEN** the login item needs approval and `signd service enable` runs
- **THEN** System Settings opens at Login Items and the command exits non-zero
