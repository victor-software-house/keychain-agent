# packaging Specification

## Purpose

How signd ships: a signed and notarized app bundle with the provisioning profile its keychain entitlement needs.
A package and a Homebrew cask install it.
The cask links the command onto the program search path (PATH).

## Requirements

### Requirement: A signed app bundle

The release SHALL be `Signd.app`, identifier `com.victor-software-house.signd`.
It SHALL be signed with a Developer ID Application identity and the hardened runtime.
Its embedded Developer ID provisioning profile SHALL authorize three things:

- its keychain access group;
- signd's iCloud container, with CloudKit in the production environment;
- push notifications.

#### Scenario: The bundle passes Gatekeeper

- **WHEN** the release package is installed
- **THEN** `spctl --assess --type execute /Applications/Signd.app` accepts it
- **AND** `codesign -d --entitlements -` on its binary lists these values:
  - the keychain access group
  - the iCloud container
  - `CloudKit`
  - the `Production` container environment
  - the push environment

### Requirement: A notarized package

The release SHALL publish `signd.pkg`, signed with a Developer ID Installer identity, notarized and stapled, which installs `Signd.app` in `/Applications`.

#### Scenario: Offline install

- **WHEN** the package is installed with no network
- **THEN** `spctl --assess --type install signd.pkg` accepts its stapled ticket

### Requirement: The command is on the search path

The package SHALL link `/usr/local/bin/signd` to the app's binary, creating `/usr/local/bin` when it is missing.
It SHALL replace a symbolic link there without following it, and SHALL leave any other file.
The cask SHALL link the command onto the program search path (PATH) under the name `signd`.
Each linked command SHALL keep the bundle's entitlements.

#### Scenario: The linked command reads the store

- **WHEN** `signd key list` runs through either link
- **THEN** it lists the same keys as `/Applications/Signd.app/Contents/MacOS/signd key list`

#### Scenario: No /usr/local/bin

- **WHEN** `/usr/local/bin` is missing and the package installs
- **THEN** `/usr/local/bin/signd` links to the app's binary

#### Scenario: A link to a folder

- **WHEN** `/usr/local/bin/signd` links to a folder and the package installs
- **THEN** `/usr/local/bin/signd` links to the app's binary, and the folder is unchanged

#### Scenario: A file of someone else's

- **WHEN** `/usr/local/bin/signd` is a regular file and the package installs
- **THEN** the file is unchanged

### Requirement: Upgrades keep keys

A newer release signed by the same team SHALL use the keys an older release stored, with no prompt and no command run.

#### Scenario: Upgrade in place

- **WHEN** a key is created and the cask upgrades signd to a newer release
- **THEN** the newer agent signs with that key

### Requirement: No private values in the repository

The repository SHALL NOT contain the signing team's identifier, provisioning profiles or certificates; the release job SHALL take them from its secrets.

#### Scenario: Search the tree

- **WHEN** the tree is searched for the team identifier and for `.provisionprofile`, `.p12` and `.cer` files
- **THEN** nothing is found

### Requirement: The package shows signd's Installer pages

The package SHALL show a background for light and for dark mode, a welcome page, the AGPL-3.0 license and a conclusion page.
It SHALL reject a Mac that is not arm64 or runs an older macOS than the deployment target, before the password prompt.

#### Scenario: An older macOS

- **WHEN** the package opens on a macOS older than the deployment target
- **THEN** Installer shows that it cannot install, and shows no password prompt

### Requirement: The cask removes what it installed

The cask's `uninstall` SHALL unregister the login item before it deletes the app, and its `zap` SHALL delete `~/Library/Application Support/signd` and `~/.ssh/signd`; neither SHALL delete a key.

#### Scenario: An uninstall

- **WHEN** `brew uninstall --cask signd` runs
- **THEN** Login Items lists no signd item, and `/Applications/Signd.app` is gone

### Requirement: The install points SSH at signd

`signd service enable` SHALL add `Include ~/.ssh/signd/config` at the top of `~/.ssh/config` when no line before the first `Host` or `Match` line includes that file.
It SHALL create the folder and the file when they are missing.
It SHALL leave the file unchanged otherwise.

#### Scenario: A config without the line

- **WHEN** `~/.ssh/config` has `Host` blocks and no `Include` of signd's file, and `signd service enable` runs
- **THEN** its first line is `Include ~/.ssh/signd/config` and the rest of the file is unchanged

#### Scenario: The line only inside a Host block

- **WHEN** `~/.ssh/config` includes signd's file only inside a `Host` block and `signd service enable` runs
- **THEN** its first line is `Include ~/.ssh/signd/config`

#### Scenario: A config with the line

- **WHEN** `~/.ssh/config` has `include signd/config` and `signd service enable` runs
- **THEN** the file is byte-identical
