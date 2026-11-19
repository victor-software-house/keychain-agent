## ADDED Requirements

### Requirement: Every user gets the agent at login

The package SHALL install a login hook that runs `signd service enable --at-login` in each user's session at login.
`--at-login` SHALL register and start the agent when it is not set up, SHALL change nothing when it is, and SHALL never open System Settings.

#### Scenario: A user who logs in after the install

- **WHEN** the package installs while no user is logged in, and a user then logs in
- **THEN** `signd status` for that user shows the agent answering, with no step by the user

#### Scenario: A user already set up

- **WHEN** a user whose agent runs logs in again
- **THEN** the hook exits 0, prints nothing, and the agent keeps its process

### Requirement: A Mobile Device Management (MDM) server approves signd with one rule

Each release SHALL attach `signd.mobileconfig`, an unsigned profile with one `com.apple.servicemanagement` rule.
The rule SHALL match `BundleIdentifier` `com.victor-software-house.signd` with the `TeamIdentifier` key set to the team that signed the release.
The release job SHALL take the team identifier from the signed app.

#### Scenario: A Mac enrolled in an MDM

- **WHEN** an MDM installs the profile and then the package on a Mac, and a user logs in
- **THEN** the agent runs for that user, Login Items lists signd's items as managed, and macOS shows no approval prompt

#### Scenario: The attached profile

- **WHEN** `signd.mobileconfig` is downloaded from a release
- **THEN** `plutil -lint` accepts it, and its `TeamIdentifier` equals the one `codesign -dv` prints for that release's app

## MODIFIED Requirements

### Requirement: The cask removes what it installed

The cask's `uninstall` SHALL unregister the login item and delete the login hook before it deletes the app.
Its `zap` SHALL delete `~/Library/Application Support/signd` and `~/.ssh/signd`.
Neither SHALL delete a key.

#### Scenario: An uninstall

- **WHEN** `brew uninstall --cask signd` runs
- **THEN** Login Items lists no signd item, `/Library/LaunchAgents/com.victor-software-house.signd.login.plist` and `/Applications/Signd.app` are gone
