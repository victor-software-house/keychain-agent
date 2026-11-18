# Design

## Context

The `wrapped-keys` change keeps each key in the keychain, sealed to a Secure Enclave key of its Mac, and the `onepassword-sync` change copies SSH Key items from 1Password into that store every five minutes.
This change replaces 1Password with the user's iCloud private database, through CloudKit.
Its data model speaks of devices, each with its own hardware-sealed key; today every device is a Mac with a Secure Enclave.
[research.md](research.md) records the trial on two Macs that this design rests on.

## Goals / Non-Goals

**Goals:**

- A new, replaced or removed shared key reaches every Mac on the account within a few seconds, best effort.
- A new Mac on the account gets every shared key with no command on any Mac.
- List and sign requests answer from the local store and never wait for iCloud.
- Neither Apple nor the signd team can read a private key, with or without Advanced Data Protection.
- No account beyond the Mac's Apple account, and no service the signd team runs.

**Non-Goals:**

- Sharing keys between Apple accounts.
- Limiting a key to some Macs. A later change may add it through tags or profiles in the configuration (operator, 2026-11-18).
- Taking keys back from a stolen Mac: it keeps the keys it holds, and the user replaces them.
- Sync in a build from source: only the signd team's provisioning profile grants the container.

## Decisions

### 1. Records

The zone `signd` in the private database holds two record types, already in the production schema, each with one encrypted bytes field, `payload`.
The payload is JSON with its own `format` number, so a later format needs no schema change.

| Record | Record name | Payload |
|:--|:--|:--|
| `Device` | `device-` and the first 16 bytes of the SHA-256 of the device's public key, in hex | `format`, `name`, `publicKey`, `version` |
| `Key` | `key-` and the key name | `format`, `name`, `comment`, `hosts`, `publicKey`, `sealed` |

A device's `name` is a Mac's `LocalHostName`, and `publicKey` is the X9.63 form of its device key.
A key's `publicKey` is its SSH public blob, and `sealed` maps each device record name to that device's sealed copy.
The production schema also holds a `Mac` type, deployed for the trial before the model was named for devices; CloudKit never deletes a deployed type, and signd neither reads nor writes it.
The record name contains the key name, so a key name is unique on the account.

### 2. The device key

Each device makes one Secure Enclave P-256 key-agreement key the first time the agent finds iCloud available.
Its handle is a keychain item in signd's access group, readable after the first unlock, on this device only, like every other signd item.
Its public half goes in the device's record.

### 3. Sealed copies

A sealed copy is `Wrapping.seal` from the `wrapped-keys` change, addressed to a device key: HPKE with P-256, SHA-256 and AES-GCM-256, bound to the key type and public blob.
A device stores its own copy as a wrapped key whose handle is its device key, so the agent opens it on first use, as it opens any wrapped key.
A shared key's source is `icloud`, and its item records the record name.

### 4. Sharing

- `signd key create` with a wrapped type and `signd key import` store the key, then ask the agent to share it, unless `--local` is given.
- The agent opens the key, seals it to every device record it knows, and saves a new Key record. It then replaces the local item with this device's sealed copy.
- A record of the same name fails the share with "a shared key named NAME exists".
- When sync is off, because the build has no iCloud entitlement or the Mac has no iCloud account, the key stays local and the command says so and exits 0.
  Any other failure leaves the key local and exits 1 with the reason and the `signd key share NAME` command to retry.
- `signd key share NAME` shares an existing key; it refuses a Secure Enclave key, which cannot leave its Mac.
- `signd key delete NAME` on a shared key deletes its record through the agent, then the local item; every other Mac deletes its copy at its next check.

The operator chose sharing by default and `--local` as the way out (operator, 2026-11-18).

### 5. New and removed devices

At each check, a device that holds a shared key compares the key's `sealed` map with the device records.
It seals the key to each device that has no copy and saves the record against the change tag it read.
It never drops a copy, because a device record newer than its last fetch may already have one.
When two devices race, the second save fails with a changed record, and that device reads the first one's record at its next check.

A device publishes its own record when the zone has none for its key, and saves it again when its `LocalHostName` changes.
`signd device remove ID` deletes a device's record and drops its copies from every key.
A running device publishes its record again at its next check, so the command is for a device that is gone.
The operator chose that a new Mac gets every key with no approval step (operator, 2026-11-18).

### 6. The check

1. Ask for database changes since the last token: one request, and nothing more when the `signd` zone did not change.
2. Ask for the zone's changes since its token until none are left: the changed and deleted `Device` and `Key` records.
3. Bring the store in line: add or replace each key whose record carries a copy for this Mac, and delete each shared key whose record is gone.
   A key with no copy for this Mac yet is reported as waiting; a key whose name a local key already has is skipped and reported.
4. Seal keys to new devices, as decision 5 says, and publish this device's record.
5. When a key changed, the agent reads the store again, which rewrites the SSH routing files of the `ssh-routing` capability.

`sync.json` keeps the change tokens and, for each record, its name, change tag, public key, hosts and the devices it is sealed to.
It contains no private key and no sealed copy.
An expired change token starts again with a full fetch.

### 7. When signd checks

- Every `interval`, 2 seconds by default, times a random factor from 0.8 to 1.2, with a quarter second of timer leeway.
- A push from the database subscription `signd-changes` starts a check at once.
  The subscription asks for a content-available push with a badge, which CloudKit sends at high priority; it sends none to the Mac that saved.
- `signd sync` runs a check now and waits for it.
- One check runs at a time, and a list or sign request neither starts nor waits for one.

### 8. Failures

| Failure | What signd does next |
|:--|:--|
| A network error, or a request past its timeout of 10 seconds | waits the interval times 2 to the power of the failures before, up to 60 seconds, times a random factor from 0.5 to 1 |
| A throttle, a busy zone or an unavailable service with a retry-after time | waits that time, and at least the interval |
| No iCloud account, or a restricted one | checks the account every 60 seconds and when macOS reports an account change |
| Another Apple account signed in | deletes the shared keys and the state, and starts again |
| The zone deleted from iCloud settings | deletes the shared keys and stops until `signd sync`, which makes the zone again |
| The zone missing for another reason | makes it again at the next check |
| An expired change token | fetches everything again |
| iCloud storage full when a key is saved | fails that share with the reason; checks go on |

The stored keys stay as they are after every failure but the account change and the deleted zone.

### 9. Pushes

`signd serve` runs an `NSApplication` with the accessory activation policy on the main thread, registers for remote notifications, and passes each push to the sync service.
The socket server runs on its own task.
A build without the iCloud entitlement runs no `NSApplication`.

### 10. Builds without iCloud

The agent reads `com.apple.developer.icloud-container-identifiers` from its own signature with `SecTaskCopyValueForEntitlement`.
Without signd's container there, it never calls CloudKit, which stops a process that lacks the entitlement, and `signd status` shows sync as off in this build.
The command line never calls CloudKit: it asks the agent.

### 11. Commands and status

- `signd sync` runs a check now and prints what changed.
- `signd device list` prints each device's name, record name and whether it is this one; `signd device remove ID` removes one.
- `signd status` shows whether iCloud is available, the last check, its result and requests, the next check, the number of devices, and each waiting or skipped key.
- `signd login` and `signd logout` go, with the token item.

### 12. Settings

`interval` defaults to 2 seconds and takes 1 second to 1 hour.
`key-lifetime` is unchanged.
The `signd` note goes; the `declarative-config` change carries settings for every Mac.

## Risks / Trade-offs

- [A request every 2 seconds is 43,200 a day per Mac] → The trial saw no throttle in an hour on two Macs; signd honours every retry-after time, and `interval` can grow.
- [Pushes to a windowless agent arrive late or not at all] → A push only starts a check early; the poll is the path.
- [The Apple account is the trust boundary] → Anyone signed in to it on a Mac running signd gets every shared key. CloudKit's encryption keys sit with Apple without Advanced Data Protection, but the sealed copies stay unreadable to Apple.
- [A stolen Mac publishes its record again] → The user erases it through Find My, which signs it out of iCloud, and replaces the keys.
- [CloudKit stops a process without the entitlement] → Decision 10 checks the signature before any CloudKit call.

## Migration Plan

1. On each Mac, run `signd logout` with the installed 1Password release, which deletes the token and the synced keys, then install this release.
2. On one Mac, import each key that 1Password held, which shares it; and run `signd key share` for each key imported by hand.
3. On every other Mac, delete the local copy of each such key; the shared copy arrives within seconds.
4. Remove the dotfiles step that signs signd in to 1Password.
5. Rollback: install the previous release and run `signd login` again.
