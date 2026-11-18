# packaging Specification

## Purpose

How signd ships: a signed and notarized app bundle with the provisioning profile its keychain entitlement needs.
A package and a Homebrew cask install it.
The cask links the command onto the program search path (PATH).

## Requirements

### Requirement: A signed app bundle

The release SHALL be `Signd.app`, identifier `com.victor-software-house.signd`.
It SHALL be signed with a Developer ID Application identity and the hardened runtime.
It SHALL embed a Developer ID provisioning profile that authorizes its keychain access group.

#### Scenario: The bundle passes Gatekeeper

- **WHEN** the release package is installed
- **THEN** `spctl --assess --type execute /Applications/Signd.app` accepts it, and `codesign -d --entitlements -` on its binary lists the keychain access group

### Requirement: A notarized package

The release SHALL publish `signd.pkg`, signed with a Developer ID Installer identity, notarized and stapled, which installs `Signd.app` in `/Applications`.

#### Scenario: Offline install

- **WHEN** the package is installed with no network
- **THEN** `spctl --assess --type install signd.pkg` accepts its stapled ticket

### Requirement: The command is on the search path

The cask SHALL link `signd` onto the PATH, and the linked command SHALL keep the bundle's entitlements.

#### Scenario: The linked command reads the store

- **WHEN** `signd key list` runs through the link
- **THEN** it lists the same keys as `/Applications/Signd.app/Contents/MacOS/signd key list`

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
