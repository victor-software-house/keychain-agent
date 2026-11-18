# key-store

## Purpose

Where signd keeps keys, which processes can use them, and how long a private key stays in signd's memory.

## ADDED Requirements

### Requirement: Keys stay in signd's access group

signd SHALL store each key as a data-protection keychain item in its own access group, available after first unlock and on this device only.
A process without that entitlement cannot read it.

#### Scenario: Another process cannot read a key

- **WHEN** an ad-hoc signed probe queries the keychain for signd's items
- **THEN** the query returns no item

#### Scenario: Keys survive a restart

- **WHEN** a key is created and signd restarts
- **THEN** `ssh-add -L` lists the key with the same public blob

### Requirement: Secure Enclave keys never leave the Secure Enclave

signd SHALL generate each Secure Enclave key as an Elliptic Curve Digital Signature Algorithm (ECDSA) P-256 key inside the Secure Enclave.
It SHALL sign with the key there, and no command SHALL output its private key.

#### Scenario: A Secure Enclave key signs

- **WHEN** `signd key create work` makes a key and `ssh-keygen -Y sign` signs through the socket
- **THEN** the signature verifies against the `ecdsa-sha2-nistp256` public key that `signd key show work` prints

### Requirement: Signing needs no user interaction

signd SHALL sign without a password, Touch ID or confirmation prompt.
This SHALL apply while the screen is locked and over SSH, once the Mac has been unlocked after boot.

#### Scenario: A locked Mac signs

- **WHEN** the screen is locked and a client connects over SSH and requests a signature
- **THEN** the signature verifies and no prompt appears

### Requirement: Keys are unavailable before first unlock

Before the first unlock after boot, signd SHALL list no stored keys, SHALL log why, and SHALL keep running.

#### Scenario: Boot without login

- **WHEN** the Mac has booted and no one has unlocked it
- **THEN** `ssh-add -L` reports no identities and signd's log shows the locked keychain

### Requirement: Decrypted keys leave memory after their lifetime

signd SHALL drop a private key in memory once it has not signed for the configured key lifetime, one hour by default.

#### Scenario: A shorter lifetime

- **WHEN** `signd config set key-lifetime 1s` is set, a key signs, and two seconds pass
- **THEN** `signd status` shows that key as not in memory
