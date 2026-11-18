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

### Requirement: The package shows signd's Installer pages

The package SHALL show a background for light and for dark mode, a welcome page, the AGPL-3.0 license and a conclusion page, and SHALL refuse a Mac that is not arm64 or runs an older macOS than the deployment target, before it asks for a password.

#### Scenario: An older macOS

- **WHEN** the package opens on a macOS older than the deployment target
- **THEN** Installer shows that it cannot install, and asks for no password

### Requirement: The cask removes what it installed

The cask's `uninstall` SHALL unregister the login item before it deletes the app, and its `zap` SHALL delete `~/Library/Application Support/signd` and `~/.ssh/signd`; neither SHALL delete a key.

#### Scenario: An uninstall

- **WHEN** `brew uninstall --cask signd` runs
- **THEN** Login Items lists no signd item, and `/Applications/Signd.app` is gone

### Requirement: The install points SSH at signd

`signd service enable` SHALL add `Include ~/.ssh/signd/config` at the top of `~/.ssh/config` when no line there includes that file, creating the folder and the file when they are missing, and SHALL leave the file unchanged otherwise.

#### Scenario: A config without the line

- **WHEN** `~/.ssh/config` has `Host` blocks and no `Include` of signd's file, and `signd service enable` runs
- **THEN** its first line is `Include ~/.ssh/signd/config` and the rest of the file is unchanged

#### Scenario: A config with the line

- **WHEN** `~/.ssh/config` has `include signd/config` and `signd service enable` runs
- **THEN** the file is byte-identical
