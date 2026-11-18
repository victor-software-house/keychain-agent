# icloud-sync

## Purpose

How signd keeps shared SSH keys the same on every Mac of one Apple account.
It uses the user's iCloud private database, and neither Apple nor the signd team can read the keys.

## ADDED Requirements

### Requirement: Shared keys are sealed to each device

signd SHALL store a shared key in the `signd` zone of the user's private database as a `Key` record.
Its encrypted payload SHALL contain the public key and one copy of the private key per device.

Each copy SHALL be sealed with Hybrid Public Key Encryption (HPKE) to that device's Secure Enclave key-agreement key.
signd SHALL NOT store a private key in the clear anywhere outside the device.

#### Scenario: A record contains only sealed copies

- **WHEN** a key is shared on an account with two Macs
- **THEN** its record's payload contains two sealed copies, and neither the payload nor `sync.json` contains the private key

### Requirement: Keys are shared by default

`signd key create` with a wrapped key type and `signd key import` SHALL share the new key unless `--local` is given.
A Secure Enclave key SHALL stay on its Mac.
`signd key share NAME` SHALL share an existing wrapped key.

#### Scenario: A new key reaches the other Mac

- **WHEN** `signd key create ci --type ed25519` runs on one Mac
- **THEN** `signd key list` on the other Mac shows `ci` with source `icloud` within a few seconds, and `ssh-keygen -Y sign` with its public key verifies there

#### Scenario: A local key stays

- **WHEN** `signd key import old file --local` runs
- **THEN** no record is saved and `signd key list` shows `old` with source `import`

#### Scenario: A Secure Enclave key stays

- **WHEN** `signd key share build` runs for a Secure Enclave key
- **THEN** the command fails with an error that the key cannot leave this Mac

### Requirement: A new device gets every shared key

A device that has a shared key SHALL seal it to each device record that has no copy, with no command on either device.

#### Scenario: A device joins

- **WHEN** signd starts on a Mac signed in to the same Apple account
- **THEN** within a few checks of the Macs that have keys, its `signd key list` shows every shared key

### Requirement: Changes reach every Mac within seconds

signd SHALL check for changes every `interval`, 2 seconds by default.
It SHALL start a check when a CloudKit push arrives.
It SHALL add, replace and delete shared keys to match their records.

#### Scenario: A key is deleted

- **WHEN** `signd key delete ci` runs on one Mac for a shared key
- **THEN** the other Mac stops listing `ci` within a few seconds

#### Scenario: The default interval

- **WHEN** no local value sets `interval`
- **THEN** `signd status` shows an interval of 2 seconds

### Requirement: An unchanged zone costs one request

A check SHALL make one request when the `signd` zone has not changed since the last check.

#### Scenario: Nothing changed

- **WHEN** `signd sync` runs after a check that saw every change, and no device has saved since
- **THEN** it reports one request

### Requirement: Requests never wait for iCloud

signd SHALL answer list and sign requests from its local store.
It SHALL NOT start or wait for a check, a CloudKit call or the account status before it answers.

#### Scenario: iCloud unreachable

- **WHEN** the network is down and `ssh-keygen -Y sign` runs with a shared key
- **THEN** the signature verifies, and `signd status` shows the failed check and the next one

### Requirement: Failures back off

signd SHALL give each CloudKit request a timeout of 10 seconds.
It SHALL wait longer after each failed check, up to 60 seconds.
After a throttle it SHALL wait at least the retry-after time CloudKit gives.

#### Scenario: Throttled

- **WHEN** CloudKit answers a check with a rate limit and a retry-after time of 30 seconds
- **THEN** `signd status` shows the next check at least 30 seconds later

### Requirement: A change of account keeps only this Mac's own keys

When another Apple account signs in, signd SHALL delete every key another device shared with the Mac.
It SHALL do the same when the user deletes signd's data in iCloud settings.
It SHALL keep each key the Mac made or imported, shared or not, as a key of this Mac only.

#### Scenario: Data deleted in iCloud settings

- **WHEN** the user deletes signd's iCloud data in System Settings
- **THEN** `signd key list` shows only the keys this Mac made or imported, none of them shared, and signd makes no zone until `signd sync` runs

### Requirement: Builds without iCloud keep local keys

A build whose signature lacks signd's iCloud container SHALL never call CloudKit.
It SHALL keep every key local.
`signd status` SHALL show that sync is off in this build.

#### Scenario: A build from source

- **WHEN** an unsigned build runs `signd serve` and `signd key create ci --type ed25519`
- **THEN** the key is stored locally, the command exits 0 with a note that sync is off, and the agent keeps serving

### Requirement: Device commands

`signd device list` SHALL print each device record's name, id and whether it is this device.
`signd device remove ID` SHALL delete that record and drop its copies from every key.

#### Scenario: Remove a device

- **WHEN** `signd device remove` runs for a Mac that has stopped running signd
- **THEN** `signd device list` no longer shows it and no record has a copy for it
