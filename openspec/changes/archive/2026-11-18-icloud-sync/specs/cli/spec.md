# cli

## MODIFIED Requirements

### Requirement: Status and settings

`signd status` SHALL show the version, the socket, whether the agent answers, and each key with whether it is in memory.
It SHALL also show the iCloud sync.
The sync part SHALL show whether it is on, the last check and its result, the next check, and each waiting or skipped key.

`signd config get|set|unset` SHALL read and change settings.

#### Scenario: Status with the agent stopped

- **WHEN** `signd service disable` has run and `signd status` runs
- **THEN** status reports that the agent does not answer and exits non-zero

#### Scenario: Status with sync off

- **WHEN** the Mac has no iCloud account and `signd status --json` runs
- **THEN** the sync section reports that iCloud is unavailable, with the reason
