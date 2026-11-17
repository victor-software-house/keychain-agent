# keychain-agent

## REMOVED Requirements

### Requirement: The agent never holds key material

**Reason**: signd holds wrapped keys in memory while they are in use, and keeps Secure Enclave keys in the Secure Enclave; the `key-store` capability states both.

**Migration**: Import each login-keychain RSA key into signd with the `wrapped-keys` change, then delete the login-keychain item.

### Requirement: The agent serves list and sign only

**Reason**: The `agent-protocol` capability replaces it with list, sign, add, remove and extensions on `~/.ssh/signd.sock`.

**Migration**: Point `IdentityAgent` or `SSH_AUTH_SOCK` at `~/.ssh/signd.sock`.

### Requirement: Releases keep the keys' access

**Reason**: The `packaging` capability replaces the binary and its keychain ACL with `Signd.app` and its access group.

**Migration**: Install the signd cask and uninstall keychain-agent once its keys are imported.
