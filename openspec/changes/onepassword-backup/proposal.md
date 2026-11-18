# Back up keys to 1Password

## Why

iCloud shares each key between the Macs of one Apple account, and it is the source of truth.
A key lost with every Mac, or deleted by mistake, needs a copy outside iCloud (operator, 2026-11-18).
1Password can also sign with an SSH Key item, so the copy works even when no Mac is left.

## What Changes

- Any live Mac copies each shareable key one way into one 1Password vault, `signd` by default, as an SSH Key item.
- The backup touches only the items it created, which carry the tag `signd`, and leaves every other item in the vault alone.
- A run comes 5 minutes after the last key change, at most once an hour, and once a day with no change.
- A `Lease` record in the signd zone keeps two Macs from running at once; it expires on its own and blocks no request.
- A removed key's item is deleted by default, which 1Password keeps in Recently Deleted for 30 days; a setting archives it or keeps it instead.
- `signd backup login` stores a service account token from stdin; `signd backup status`, `run` and `restore` show, start and undo a backup.
- Secure Enclave keys cannot leave the chip, so one Secure Note lists them for recreation.

## Capabilities

### New Capabilities

- `onepassword-backup`: the one-way copy into 1Password, its schedule, its lease, the token and the restore.

### Modified Capabilities

- `cli`: the `signd backup` commands, and the backup's state in `signd status`.

## Impact

- The rule that no private key leaves signd gains one exception: the backup vault, written only through its own service account.
- `swift-onepassword` returns as a dependency, and gains batch create and delete, `put` and `archive`.
- The production CloudKit schema gains the `Lease` record type.
- Settings from the declarative configuration change (`openspec/changes/declarative-config`): `backupVault`, `backupDelay`, `backupInterval`, `backupDailyInterval` and `backupRemoved`.
