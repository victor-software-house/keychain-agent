# updates

## ADDED Requirements

### Requirement: The updater installs a newer verified release

The updater SHALL check the latest release every `update-interval`.
It SHALL install a newer version only when its app is notarized and signed by the running code's team with the identifier `com.victor-software-house.signd`.
After the swap, it SHALL restart each running agent on the new binary.

#### Scenario: A newer release

- **WHEN** a newer release with a valid `Signd.app.zip` is out
- **THEN** the installed app's version is the new one, it is still owned by root, and each agent answers from the new binary

#### Scenario: A foreign signature

- **WHEN** the zip contains an app signed by another team
- **THEN** the installed app is unchanged, and `signd status` shows the signature error

### Requirement: Updates follow the machine's settings

With `updates` off in the managed or the machine-wide preferences, the updater SHALL make no update request.
A user's own preferences SHALL NOT change what the updater does.

#### Scenario: A managed Mac

- **WHEN** a Mobile Device Management (MDM) profile sets `updates` to false
- **THEN** the updater sends no request to the GitHub API, and `signd status` shows `updates  off (managed)`
