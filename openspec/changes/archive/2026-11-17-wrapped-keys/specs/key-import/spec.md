# key-import

## Purpose

Which private keys signd accepts besides Secure Enclave keys, how it imports or generates them, and how it keeps them usable only by signd.

## ADDED Requirements

### Requirement: Supported key types

signd SHALL import and serve Ed25519 keys.
It SHALL also import and serve Elliptic Curve Digital Signature Algorithm (ECDSA) keys on P-256, P-384 and P-521.
Rivest–Shamir–Adleman (RSA) keys of 2048 to 8192 bits SHALL be imported and served too.
signd SHALL reject every other key with a message that shows the type.

#### Scenario: A small RSA key is refused

- **WHEN** `signd key import old rsa1024.key` runs
- **THEN** the command fails, reports RSA 1024 as unsupported, and stores nothing

### Requirement: Import unencrypted keys

`signd key import NAME FILE` and `signd key import NAME -` SHALL accept an unencrypted private key from a file or from stdin.
The key SHALL be in OpenSSH format or in Public-Key Cryptography Standards (PKCS) format, PKCS#1 or PKCS#8.
The commands SHALL store it wrapped under a new Secure Enclave key.

#### Scenario: Import from stdin

- **WHEN** an unencrypted Ed25519 key is piped into `signd key import ci -`
- **THEN** `signd key show ci` prints the same public key as `ssh-keygen -y` on that file, and a signature through the socket verifies

### Requirement: Import passphrase-protected keys

For a passphrase-protected file, `signd key import NAME FILE` SHALL take the passphrase through the prompt of the system `ssh-add`, and SHALL NOT write the decrypted key to any file.

#### Scenario: Protected key

- **WHEN** `signd key import legacy protected.key` runs and the passphrase is entered
- **THEN** `signd key list` shows `legacy`, and no new file containing the key exists under the temporary directory or the home directory

#### Scenario: Protected key on stdin

- **WHEN** a passphrase-protected key is piped into `signd key import legacy -`
- **THEN** the command fails and says that a protected key must be given as a file

### Requirement: Generate wrapped keys

`signd key create NAME --type ed25519|rsa-3072|rsa-4096` SHALL generate the key, store it wrapped, and print only its public key.

#### Scenario: Generate Ed25519

- **WHEN** `signd key create deploy --type ed25519` runs
- **THEN** stdout has one `ssh-ed25519` line and nothing else, and the key signs through the socket

### Requirement: A wrapped key opens only with its own Secure Enclave key

signd SHALL bind each wrapped key to its own Secure Enclave key-agreement key and to its public key.
It SHALL NOT serve an item whose ciphertext fails to open.

#### Scenario: A tampered item

- **WHEN** a test replaces one wrapped item's ciphertext with another's, and a sign request targets that key
- **THEN** signd logs the failed open, rejects the signature, leaves that key out of its identities afterwards, and serves the others

### Requirement: Wrapped keys sign fast once open

After a wrapped key's first signature, signd SHALL sign with it without the Secure Enclave, until the key lifetime drops it.

#### Scenario: Warm signatures

- **WHEN** an Ed25519 wrapped key signs 1000 times through the socket from one connection
- **THEN** the p50 time from request to reply is under 1 ms after the first signature
