# keychain-agent Specification

## Purpose

keychain-agent serves SSH keys the keychain will not export, signing through the Security framework so that no key material reaches the agent or any other process.

## Requirements

### Requirement: The agent never holds key material

keychain-agent SHALL sign with `SecKeyCreateSignature` on a keychain key reference, and SHALL NOT request a private key's data.

#### Scenario: The key refuses export

- **WHEN** `mise run ci:e2e` imports a throwaway RSA key with `security import -x` and serves it
- **THEN** `security export -t privKeys` fails for that keychain

### Requirement: The agent serves list and sign only

keychain-agent SHALL answer "request identities" with the RSA keys of its labels, SHALL answer "sign" for those keys with the hash the request's flags name, and SHALL send `SSH_AGENT_FAILURE` for every other message.

#### Scenario: ssh tools use the agent

- **WHEN** `mise run ci:e2e` runs on macOS
- **THEN** `ssh-add -L` lists the throwaway key, and a signature from `ssh-keygen -Y sign` verifies with `ssh-keygen -Y verify`

#### Scenario: Other messages fail

- **WHEN** the message body starts with a type other than 11 or 13, or a sign request is cut short
- **THEN** the reply is the single byte 5, as `AgentProtocolTests` checks

### Requirement: Releases keep the keys' access

The release binary SHALL be signed with a Developer ID Application identity, with the hardened runtime and identifier `com.victor-software-house.keychain-agent`, in a signed, notarized and stapled `keychain-agent.pkg` that installs `/usr/local/bin/keychain-agent`.

#### Scenario: A new release signs with no change on the Mac

- **WHEN** a key was imported with `-x -T /usr/local/bin/keychain-agent` and partition list `teamid:<the release team>`, and a newer release replaces the binary
- **THEN** the newer binary signs with the key and no prompt appears, while an unsigned build of the same source is refused
