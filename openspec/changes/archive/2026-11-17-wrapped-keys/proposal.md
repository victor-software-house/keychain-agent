# Proposal

## Why

The Secure Enclave stores only P-256 keys.
Many services and accounts need Ed25519 or Rivest–Shamir–Adleman (RSA) keys, and some keys already exist and must be brought in rather than generated.

After the `signd-agent` change, signd can serve only keys it generated in the Secure Enclave.
This change lets it store any common SSH key, under the same rule that only signd can use it.

## What Changes

- New: wrapped keys.
  An Ed25519, Elliptic Curve Digital Signature Algorithm (ECDSA) or RSA private key is encrypted to a Secure Enclave key-agreement key.
  The encryption is Hybrid Public Key Encryption (HPKE), and the result is stored in signd's access group.
  signd decrypts it on first use and keeps it in memory for the key lifetime.
- New: `signd key import NAME FILE` and `signd key import NAME -` for OpenSSH and PEM private key files.
  signd parses unencrypted files itself.
  For a passphrase-protected file, signd runs the system `ssh-add`, which decrypts it and hands the key to signd over a private socket.
  No decrypted copy touches the disk.
- New: `signd key create NAME --type ed25519|rsa-3072|rsa-4096` generates a wrapped key.
- Changed: `signd key create` keeps `--type secure-enclave` as its default.

## Capabilities

### New Capabilities

- `key-import`: which private keys signd accepts, how it imports and generates them, and how it wraps them.

### Modified Capabilities

None.
The `key-store` capability, added by the `signd-agent` change, already states that only signd can read stored keys.
It also states that decrypted keys leave memory after their lifetime.
Wrapped keys follow both.

## Impact

- Code: `SSHWire` gains the unencrypted OpenSSH private key format.
  `KeyStore` gains the wrapped kind.
  The command line gains `key import` and the `--type` option.
- Dependency: the system `/usr/bin/ssh-add` for passphrase-protected files only.
- Users: keychain-agent's RSA keys can move to signd, which ends keychain-agent.
