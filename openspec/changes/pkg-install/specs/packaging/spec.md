# packaging

## MODIFIED Requirements

### Requirement: The command is on the PATH

The package SHALL link `/usr/local/bin/signd` to the app's binary, replacing a symbolic link there and leaving any other file, and the cask SHALL link `signd` onto the PATH.
Each linked command SHALL keep the bundle's entitlements.

#### Scenario: The linked command reads the store

- **WHEN** `signd key list` runs through either link
- **THEN** it lists the same keys as `/Applications/Signd.app/Contents/MacOS/signd key list`

#### Scenario: A file of someone else's

- **WHEN** `/usr/local/bin/signd` is a regular file and the package installs
- **THEN** the file is unchanged

## ADDED Requirements

### Requirement: The install points SSH at signd

`signd service enable` SHALL add `Include ~/.ssh/signd/config` at the top of `~/.ssh/config` when no line there includes that file, creating the folder and the file when they are missing, and SHALL leave the file unchanged otherwise.

#### Scenario: A config without the line

- **WHEN** `~/.ssh/config` has `Host` blocks and no `Include` of signd's file, and `signd service enable` runs
- **THEN** its first line is `Include ~/.ssh/signd/config` and the rest of the file is unchanged

#### Scenario: A config with the line

- **WHEN** `~/.ssh/config` has `include signd/config` and `signd service enable` runs
- **THEN** the file is byte-identical
