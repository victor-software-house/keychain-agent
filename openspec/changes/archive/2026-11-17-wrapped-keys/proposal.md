# Proposal

## Why

The Secure Enclave holds only P-256 keys, while many services and existing accounts need Ed25519 or RSA, and some keys already exist and must be brought in rather than generated.
After the `signd-agent` change, signd can serve only keys it generated in the Secure Enclave; this change lets it hold any common SSH key with the same rule that only signd can use it.

## What Changes

- New: wrapped keys. An Ed25519, ECDSA or RSA private key is encrypted with HPKE to a Secure Enclave key-agreement key and stored in signd's access group.
  signd decrypts it on first use and keeps it in memory for the key lifetime.
- New: `signd key import NAME FILE` and `signd key import NAME -` for OpenSSH and PEM private key files.
  Unencrypted files are parsed by signd; for a passphrase-protected file signd runs the system `ssh-add`, which decrypts it and hands the key to signd over a private socket, so no decrypted copy touches the disk.
- New: `signd key create NAME --type ed25519|rsa-3072|rsa-4096` generates a wrapped key.
- Changed: `signd key create` keeps `--type secure-enclave` as its default.

## Capabilities

### New Capabilities

- `key-import`: which private keys signd accepts, how it imports and generates them, and how it wraps them.

### Modified Capabilities

None. The `key-store` capability, added by the `signd-agent` change, already states that only signd can read stored keys and that decrypted keys leave memory after their lifetime; wrapped keys follow both.

## Impact

- Code: `SSHWire` gains the unencrypted OpenSSH private key format; `KeyStore` gains the wrapped kind; the CLI gains `key import` and the `--type` option.
- Dependency: the system `/usr/bin/ssh-add` for passphrase-protected files only.
- Users: keychain-agent's RSA keys can move to signd, which ends keychain-agent.
