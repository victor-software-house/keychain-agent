# configuration

## Purpose

Where signd's settings and declared keys come from, in what order, and how a change reaches the running agent.

## ADDED Requirements

### Requirement: Settings come from the profile, the file and the default, in that order

signd SHALL take each setting from the first of these sources that sets it:

1. The domain's managed preferences from a Mobile Device Management (MDM) profile.
2. `~/.config/signd/config.toml`.
3. The built-in default.

#### Scenario: The file sets the interval

- **WHEN** the file sets `interval` to `10m` and no profile sets it
- **THEN** `signd status` shows an interval of 10 minutes from the file

#### Scenario: A profile wins

- **WHEN** a profile sets `interval` to `30m` and the file sets `10m`
- **THEN** `signd status` shows 30 minutes from the profile

### Requirement: A change applies without a restart

The agent SHALL apply a change to the file or to the profile's managed preferences within one second, and SHALL NOT poll for changes.

#### Scenario: The file is replaced by rename

- **WHEN** a tool writes a new file to a temporary name and renames it over the old one
- **THEN** `signd status` shows the new values within one second, with no command run

### Requirement: A bad file is rejected whole

signd SHALL reject a file that does not parse or contains an unknown name or a bad value.
It SHALL keep the last configuration that loaded.
It SHALL report the error with its line in `signd status`.

#### Scenario: A typo

- **WHEN** the file sets `refresh = "5m"`, a name signd does not know
- **THEN** the agent keeps its previous values and `signd status` shows the unknown key and its line

### Requirement: Declared keys exist, and only they are removed

At apply, signd SHALL create each declared key that does not exist.
It SHALL update the hosts and comment of a key it created from the file.
A key it created from the file whose entry is gone SHALL be deleted.
A key made by command or shared from another Mac SHALL NOT be changed or deleted.

#### Scenario: An entry is removed

- **WHEN** an entry for a key created from the file is deleted from the file
- **THEN** `signd key list` no longer shows that key

#### Scenario: An entry names a command-made key

- **WHEN** an entry is for a key made with `signd key create`
- **THEN** that key is unchanged and `signd status` reports the conflict
