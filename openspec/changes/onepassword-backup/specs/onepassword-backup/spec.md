# onepassword-backup

## ADDED Requirements

### Requirement: The backup copies shareable keys one way

With a token stored, signd SHALL keep one SSH Key item per shareable key in the backup vault, tagged `signd`, with the key's private key, hosts and comment.  
It SHALL never change a key from the vault's content.

#### Scenario: A new key

- **WHEN** a key is shared and the backup runs
- **THEN** the vault holds an SSH Key item with that key's name, tagged `signd`, whose public key matches the key

### Requirement: The backup touches only its own items

signd SHALL read, change and remove only items tagged `signd` in the backup vault.

#### Scenario: A user's item in the vault

- **WHEN** the vault holds an item without the tag and the backup runs
- **THEN** that item is unchanged

### Requirement: A removed key's item follows the setting

When a key is gone from the store, signd SHALL delete its item by default, archive it when `backupRemoved` is `archive`, and leave it when `backupRemoved` is `keep`.

#### Scenario: A deleted key with the default

- **WHEN** a shared key is deleted and the backup runs
- **THEN** its item is in the vault's Recently Deleted, and no other item changed

### Requirement: Runs follow the schedule and one Mac runs at a time

signd SHALL run the backup `backupDelay` after the last key change, at most once per `backupInterval`, and once per `backupDailyInterval` with no change.  
It SHALL run only while it holds the `Lease` record, and SHALL take over a lease past its expiry.

#### Scenario: Two Macs at once

- **WHEN** two Macs reach a run in the same second
- **THEN** one runs and the other skips this slot

#### Scenario: A holder that stopped

- **WHEN** the lease holder stopped mid-run and its expiry passed
- **THEN** the next Mac's run takes the lease and runs

### Requirement: A backup never delays a request

No SSH request and no key change SHALL wait on 1Password or on the lease.

#### Scenario: 1Password unreachable

- **WHEN** 1Password does not answer during a run
- **THEN** SSH requests sign as fast as before, and `signd status` shows the failed run

### Requirement: A restore imports keys from the backup

`signd backup restore` SHALL import the named items, or every tagged item with `--all`, as shared keys, or local ones with `--local`, and SHALL skip a key the store already holds.

#### Scenario: A Mac with no keys

- **WHEN** the store is empty and `signd backup restore --all` runs
- **THEN** the store holds every key the vault's tagged items hold, and each signs
