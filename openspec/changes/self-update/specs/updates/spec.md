# updates

## ADDED Requirements

### Requirement: The agent installs a newer verified release

The agent SHALL check the latest release 60 seconds after start and every `updateInterval`.
It SHALL install a newer version only when its app is notarized and signed by the running code's team with the identifier `com.victor-software-house.signd`.

#### Scenario: A newer release

- **WHEN** a newer release with a valid `Signd.app.zip` is out
- **THEN** the installed app's version is the new one, and the agent answers from the new binary

#### Scenario: A foreign signature

- **WHEN** the zip contains an app signed by another team
- **THEN** the installed app is unchanged, and `signd status` shows the signature error

### Requirement: Updates follow the settings

With `updates` off, or with a bundle the user cannot write, the agent SHALL make no update request.

#### Scenario: A root-owned bundle

- **WHEN** `Signd.app` belongs to root
- **THEN** the agent sends no request to the GitHub API, and `signd status` shows `updates  managed`
