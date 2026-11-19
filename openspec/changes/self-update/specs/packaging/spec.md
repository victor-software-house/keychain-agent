# packaging

## ADDED Requirements

### Requirement: The release publishes the app zip

Each release SHALL attach a notarized, stapled `Signd.app.zip` beside `signd.pkg`, and the cask SHALL set `auto_updates true`.

#### Scenario: The asset

- **WHEN** a release is published
- **THEN** `Signd.app.zip` unpacks to an app that passes `spctl --assess --type execute`

### Requirement: The package installs the updater

The package SHALL install the updater daemon's plist in `/Library/LaunchDaemons`, owned by `root:wheel` with mode 0644, and SHALL leave `/Applications/Signd.app` owned by root.

#### Scenario: After the install

- **WHEN** the package installs
- **THEN** `launchctl print system/com.victor-software-house.signd.updater` finds the job, and `stat -f %Su /Applications/Signd.app` prints `root`
