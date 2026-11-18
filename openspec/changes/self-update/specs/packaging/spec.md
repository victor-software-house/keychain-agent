# packaging

## ADDED Requirements

### Requirement: The release publishes the app zip

Each release SHALL attach a notarized, stapled `Signd.app.zip` beside `signd.pkg`, and the cask SHALL set `auto_updates true`.

#### Scenario: The asset

- **WHEN** a release is published
- **THEN** `Signd.app.zip` unpacks to an app that passes `spctl --assess --type execute`

### Requirement: The package hands the app to the user

The package's postinstall SHALL make the console user the owner of `/Applications/Signd.app`, unless a managed setting turns updates off.

#### Scenario: An unmanaged Mac

- **WHEN** the package installs on a Mac with no signd profile
- **THEN** `stat -f %Su /Applications/Signd.app` prints the console user
