# Design

## Context

Each Mac's store mirrors the keys shared through iCloud, and holds its own Secure Enclave keys.
`swift-onepassword` reads vaults and items today; the [SDK source][sdk-items] also offers `createAll` and `deleteAll` within one vault, `put` for one item, `archive`, and a list filter by state.
1Password keeps a deleted item in Recently Deleted for 30 days, and an archived one until it is restored ([support][op-delete]).

## Decisions

### 1. Ownership and scope

Every item the backup writes carries the tag `signd`, and a `signd` section with its `kind` and `scope`.
An item is signd's only when it has the tag and a well-formed section; any other item, tagged or not, is never changed or removed.
A section is well-formed when its `kind` is one of the two below, its `scope` is `shared` or a device identifier, and a `key` section has a `SHA256:` fingerprint and a name.
The device identifier comes from the Mac's `Device` record, never from its editable name.

| `kind` | What the item holds | `scope` |
|:--|:--|:--|
| `key` | One key, with its fingerprint and signd name | `shared`, or `local` with a device identifier |
| `secure-enclave-list` | One Mac's Secure Enclave keys | that Mac's device identifier |

### 2. Item shape

A `key` item is an SSH Key item titled with the key's name, holding the private key, a `hosts` text field and the comment.
A `secure-enclave-list` item is a Secure Note, `signd Secure Enclave keys (<device name>)`, with each key's name, public key and hosts, for recreation.

### 3. A run

A run plans each scope from the source that knows it:

- Shared keys come from the `Key` records in CloudKit, the source of truth, never from the local store, which a new Mac fills only after its first fetch.
- This Mac's local keys and its Secure Enclave list come from its own store; no Mac plans another Mac's local items.

It then applies the difference in as few calls as the SDK allows:

| Difference | Call |
|:--|:--|
| A key with no item | `createAll`, up to 100 items a call |
| An item whose fields differ from its source | `put`, one call per changed item |
| An item whose key is gone | `deleteAll` up to 50 a call, `archive` each, or nothing, by `backupRemoved` |

Removals of shared items come only from a full CloudKit zone fetch, started with no change token, that completed in the same run: every page returned, with no error and no more-coming flag left set.
A partial or failed read removes nothing and records why in `signd status`.
A completed full fetch is authoritative even when it lists no keys, so deleting the last shared key removes its item too.
No run removes an item whose fingerprint matches a key in this Mac's store, whatever its scope.
A Mac's `secure-enclave-list` item is updated with `put` and removed only when that Mac's `Device` record is gone from a completed read.
Two items with one fingerprint, as 1Password's Duplicate makes, both count: a run updates the oldest and leaves the others alone, and a removal removes every copy.
The list call returns overviews, which carry the tags and `updatedAt` but no section.
Each Mac keeps a local cache, with no secret in it, of each item's identifier, `updatedAt` and the change tag of the source it last wrote.
A run fetches full items with `getAll`, up to 50 a call, only for items that are new to the cache or whose `updatedAt` moved.
A run with no difference, on a Mac whose cache is current, makes only the list call.
The run happens in a task of its own, never on the event loop or inside the agent actor, so a slow 1Password call delays no SSH request.

### 4. Schedule

`backupDelay` (5 minutes) after the last key change, at most once per `backupInterval` (1 hour), and once per `backupDailyInterval` (1 day) with no change.
Each is a setting with that default, which the config file or an MDM profile can change.
A failed run records its error for `signd status` and waits for the next slot; it never retries in a loop.

### 5. Lease

CloudKit has no record expiry in its public API, so the lease is a `Lease` record named `backup` with the holder's device identifier and an expiry 10 minutes out.
A Mac claims it with a save that uses `ifServerRecordUnchanged`, so two claims cannot both succeed.
A lease past its expiry counts as free, and the same save takes it over.
The holder renews it with the same conditional save before each batch of calls, and stops the run when a renewal fails.
It clears the lease at the end with a conditional save too, so a late clear never removes another Mac's claim.
Only the backup reads the lease, so no key change or SSH request ever waits on it.

### 6. Token

`signd backup login` reads a service account token from stdin and checks that it can write to the vault.
It stores the token in the data-protection keychain in signd's access group, on this device only.
Other Macs receive it sealed to their Secure Enclave keys, as keys are, so one login serves every Mac.
The token never appears in a file, an argument, the environment or a log.
Its service account can write only to the backup vault; `signd backup logout` deletes the token on every Mac.

### 7. Restore

`signd backup restore` lists the tagged items, and imports the named ones, or `--all`, through the same path as `signd key import`.
A restored key is shared by default, and `--local` keeps it on this Mac.
A key whose fingerprint the store already holds is skipped.

### 8. Settings

| Setting | Default |
|:--|:--|
| `backupVault` | `signd` |
| `backupDelay` | 5 minutes |
| `backupInterval` | 1 hour |
| `backupDailyInterval` | 1 day |
| `backupRemoved` | `delete`; also `archive` or `keep` |

With no token, the backup stays off, and `signd status` shows it as off.

## Risks

- A token that leaks can read and write the backup vault, which holds private keys.
  Its service account has no other vault, and a revoke in 1Password ends it at once.
- `put` has no batch form, so a run that changes many items makes one call per item.

[sdk-items]: https://github.com/1Password/onepassword-sdk-js/blob/0ba88b1496f23d4c68b87dcd771651fe73a14375/client/src/items.ts
[op-delete]: https://support.1password.com/archive-delete-items/
