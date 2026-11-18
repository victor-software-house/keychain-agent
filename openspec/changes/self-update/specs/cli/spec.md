# cli

## ADDED Requirements

### Requirement: update checks now

`signd update` SHALL make the agent check at once, and SHALL print the version found and whether it was installed.

#### Scenario: No newer release

- **WHEN** the running version is the latest
- **THEN** `signd update` prints that signd is up to date and exits zero
