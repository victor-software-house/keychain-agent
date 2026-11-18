# keychain-agent

## REMOVED Requirements

### Requirement: The agent never keeps key material

**Reason**: signd keeps wrapped keys in memory while they are in use.
It keeps Secure Enclave keys in the Secure Enclave.
The `key-store` capability states both.

**Migration**: Import each login-keychain Rivest–Shamir–Adleman (RSA) key into signd with the `wrapped-keys` change, then delete the login-keychain item.

### Requirement: The agent serves list and sign only

**Reason**: The `agent-protocol` capability replaces it.
It provides list, sign, add, remove and extensions on `~/.ssh/signd.sock`.

**Migration**: Point `IdentityAgent` or `SSH_AUTH_SOCK` at `~/.ssh/signd.sock`.

### Requirement: Releases keep the keys' access

**Reason**: The `packaging` capability replaces the binary and its access control list (ACL) in the keychain with `Signd.app` and its access group.

**Migration**: Install the signd cask and uninstall keychain-agent once its keys are imported.
