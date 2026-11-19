# Design

## Context

Each Mac's store mirrors the keys shared through iCloud and also stores its own Secure Enclave keys.
`swift-onepassword` reads vaults and items today.
The [SDK source][sdk-items] also offers `createAll` and `deleteAll` within one vault, `put` for one item, `archive`, and a list filter by state.

1Password keeps a deleted item in Recently Deleted for 30 days, and an archived one until it is restored ([support][op-delete]).

## Decisions

### 1. Ownership and scope

Every item the backup writes carries the tag `signd`, and a `signd` section with its `kind` and `scope`.
An item is signd's only when it has the tag and a well-formed section.
Any other item, tagged or not, is never changed or removed.

A section is well-formed when all of these are true:

- Its `kind` is one of the two below.
- Its `scope` is `shared` or a device identifier.
- A `key` section has a `SHA256:` fingerprint and a name.

The device identifier comes from the Mac's `Device` record, never from its editable name.

| `kind` | What the item contains | `scope` |
|:--|:--|:--|
| `key` | One key, with its fingerprint and signd name | `shared`, or `local` with a device identifier |
| `secure-enclave-list` | One Mac's Secure Enclave keys | that Mac's device identifier |

### 2. Item shape

A `key` item is an SSH Key item titled with the key's name, that contains the private key, a `hosts` text field and the comment.
A `secure-enclave-list` item is a Secure Note, `signd Secure Enclave keys (<device name>)`, with each key's name, public key and hosts, for recreation.

### 3. A run

A run plans each scope from its own source:

- Shared keys come from the `Key` records in CloudKit, which decide what exists.
  They never come from the local store, which a new Mac fills only after its first fetch.
- This Mac's local keys and its Secure Enclave list come from its own store; no Mac plans another Mac's local items.

It then applies the difference in as few calls as the SDK allows:

| Difference | Call |
|:--|:--|
| A key with no item | `createAll`, up to 100 items a call |
| An item whose fields differ from its source | `put`, one call per changed item |
| An item whose key is gone | `deleteAll` up to 50 a call, `archive` each, or nothing, by `backupRemoved` |

Removals of shared items come only from a full CloudKit zone fetch that completed in the same run.
The fetch starts with no change token.
Completed means every page returned, with no error and no more-coming flag left set.

A failed read removes nothing and records why in `signd status`.

A completed read that could not return a record still ends every record it did not list, except that record.
The record keeps its last known state, and the read saves its change tokens.
Each check, full or not, reads such a record again by name, and `signd status` shows how many are left.

While a `Key` record cannot be read, the backup removes no shared item, since that record's fingerprint is unknown.

A completed full fetch is trusted even when it lists no keys, so deleting the last shared key removes its item too.

No run removes an item whose fingerprint matches a key in this Mac's store, whatever its scope.
A Mac's `secure-enclave-list` item is updated with `put` and removed only when that Mac's `Device` record is gone from a completed read.

Two items can have one fingerprint, as 1Password's Duplicate makes them.
Both count: a run writes nothing when any copy is current.
Otherwise it updates one copy and leaves the others alone.

A run writes to the copy the cache records, while that item exists, and otherwise to the oldest by `updatedAt`, then by identifier.
A removal removes every copy.

The list call returns overviews, which carry the tags and `updatedAt` but no section.
Each Mac keeps a local cache with no secret in it.
The cache has these for each item:

- its identifier and `updatedAt`
- the change tag of the source it last wrote
- the slot and name of its owner
- the identifier of the copy a run writes to, when the slot has duplicates

A run fetches full items with `getAll`, up to 50 a call, only for items that are new to the cache or whose `updatedAt` moved.
A run with no difference, on a Mac whose cache is current, makes only the list call.

The run happens in a task of its own, never on the event loop or inside the agent actor.
So a slow 1Password call delays no SSH request.

### 4. Schedule

A run starts `backupDelay` (5 minutes) after the last key change, at most once per `backupInterval` (1 hour).
With no change, it runs once per `backupDailyInterval` (1 day).

Each is a setting with that default, read through signd's existing settings.
`signd config` or a device management profile can change it.
A failed run records its error for `signd status` and waits for the next slot.
It never retries in a loop.

### 5. Lease

CloudKit has no record expiry in its public API.
So the lease is a `Lease` record called `lease-backup`, whose payload has the holder's device identifier and an expiry 10 minutes out.
Like every signd record, it keeps that payload in one encrypted field.

A Mac claims it with a save that uses `ifServerRecordUnchanged`, so two claims cannot both succeed.
A lease past its expiry counts as free, and the same save takes it over.

Each Mac reads the expiry against its own clock, so clocks more than the lease length apart break the exclusion.
Only the backup reads the lease, so no key change or SSH request ever waits on it.

The holder renews it with the same conditional save before each batch of calls, and stops the run when a renewal fails.
It clears the lease at the end with a conditional save too, so a late clear never removes another Mac's claim.

### 6. Token

`signd backup login` reads a service account token from stdin and checks that the service account lists the vault; the first run reports a vault it cannot write.

The command stores the token in the data-protection keychain in signd's access group, on this device only.
Other Macs receive it sealed to their Secure Enclave keys, as keys are, so one login serves every Mac.

The sealed copies live in a `Backup` record called `backup-token`.
Its payload has the vault name and one sealed copy of the token per device, keyed by the device's record name.
A `Key` record's payload keeps its key the same way.

The check that seals shared keys for a new Mac seals the token for it too.
The sealing takes bytes, so it uses the hybrid public key encryption (HPKE) of `Wrapping` without a `PrivateKey`.

A Mac that opens its copy stores the token in its keychain under its own service name, never beside the keys.

The token never appears in a file, an argument, the environment or a log.
Its service account can write only to the backup vault.
`signd backup logout` deletes the `Backup` record, and each Mac deletes its stored token when a check no longer reads the record.

### 7. Restore

`signd backup restore` lists the tagged items, and imports the ones picked by name, or `--all`, through the same path as `signd key import`.
A restored key is shared by default, and `--local` keeps it on this Mac.
A key whose fingerprint the store already contains is skipped.

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

- A token that leaks can read and write the backup vault, which stores private keys.
  Its service account has no other vault, and a revoke in 1Password ends it at once.
- `put` has no batch form, so a run that changes many items makes one call per item.

[sdk-items]: https://github.com/1Password/onepassword-sdk-js/blob/0ba88b1496f23d4c68b87dcd771651fe73a14375/client/src/items.ts
[op-delete]: https://support.1password.com/archive-delete-items/
