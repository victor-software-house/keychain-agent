# Proposal

## Why

The `onepassword-sync` change brings a key change to every Mac within one interval of five minutes, and each check costs a read from a daily 1Password quota.
The operator wants a change to reach every Mac within a few seconds, with no account beyond the Apple account each Mac already has, and asked to drop 1Password (operator, 2026-11-18).
A trial on two Macs measured CloudKit's private database: a check every 2 seconds saw 142 of 142 saves from the other Mac within 3.4 seconds, with no throttling in 3,943 checks ([research.md](research.md)).

## What Changes

- New: signd keeps shared keys in the user's own iCloud private database, in a zone named `signd`, as `Key` records.
  Each device publishes a `Device` record with the public half of its own Secure Enclave key-agreement key; today every device is a Mac.
- New: a shared key's private part is sealed with HPKE to each device's key, inside CloudKit's encrypted field, so neither Apple nor the signd team can read it.
- New: keys sync by default.
  `signd key create` and `signd key import` share every key that can leave the Mac, and `--local` keeps a key on its Mac; a Secure Enclave P-256 key never leaves it.
  `signd key share NAME` shares an existing key, and `signd key delete` on a shared key deletes it on every Mac.
- New: a Mac that has a shared key seals it to each new Mac on the account at its next check, with no step on either Mac.
- New: the agent checks for changes every 2 seconds, one request when nothing changed, and a push from CloudKit starts a check at once.
  Each request times out after 10 seconds, failures back off, and a throttled check waits the time CloudKit gives.
- New: `signd device list` and `signd device remove`.
- **BREAKING** Removed: `signd login`, `signd logout`, the 1Password sync, the `signd` note and the `swift-onepassword` dependency.
  A key synced from 1Password stays on its Mac as a local key until it is shared or deleted.
- Changed: the `interval` setting defaults to 2 seconds, from 1 second to 1 hour.
- Changed: the release signs the app with the iCloud and push entitlements of its provisioning profile.
- A build without signd's iCloud entitlement, such as one built from source, keeps local keys only, with sync off.

## Capabilities

### New Capabilities

- `icloud-sync`: the records, sealing, checks, pushes, failures and commands of the sync through iCloud.

### Modified Capabilities

- `onepassword-sync`: removed.
- `cli`: `signd status` shows the iCloud sync.
- `ssh-routing`: a key's hosts come from its record.
- `packaging`: the app carries the iCloud and push entitlements.

## Impact

- Code: the `Sync` module moves to CloudKit; `KeyStore` gains the device key and loses the token store; the agent runs an `NSApplication` to receive pushes.
- CI: the 1Password test secret leaves the template answers, and the tests run against a CloudKit stand-in.
- Each Mac: the dotfiles step that signs signd in to 1Password goes.
