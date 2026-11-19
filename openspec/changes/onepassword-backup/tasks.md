# Tasks

## 1. Code

- [x] 1.1 Add batch create and delete, `put` and `archive` to `swift-onepassword`.
  Verify its live tests create, update, archive and delete an item in its test vault.
  - 2026-11-19 UTC: [swift-onepassword 0.0.4][so-004] ships the writes.
    Its live test creates, reads, updates and deletes two items in its test vault, and leaves none behind.
    It does not archive: the SDK cannot delete an archived item, so a Go stub test covers `archive`.
- [x] 1.2 Store the token by design decision 6, with `signd backup login` and `logout`.
  Verify unit tests that no file, argument or log contains it.
  - 2026-11-19 UTC: Unit tests cover a sealed payload that never contains the token.
    They cover a login with an argument, which exits with the stdin message.
    They also cover a check that stores the token and seals it for a new Mac.
    Another check deletes it when the record, the zone or the account is gone.
  - 2026-11-19 UTC: More unit tests cover a Mac with no copy in the record, which deletes its token and seals nothing.
    They cover a removed device, whose copy leaves the record.
  - 2026-11-19 UTC: Unit tests also cover a read with an unreadable record.
    A full read applies every record it returns and advances the change tokens.
    It removes what it does not list, except the records it could not read.
    Those keep their last known state, the next check is incremental, and each check reads them by name.
  - 2026-11-19 UTC: Unit tests also cover a state file and results that contain neither the token nor its base64.
  - 2026-11-19 UTC: The prompt that reads the token with echo off has no test, as it needs a terminal.
- [x] 1.3 Plan a run by design decisions 1 to 3, scope by scope.
  Verify unit tests of the plan for new, changed, removed and foreign items, and for each `backupRemoved` value.
  Verify unit tests for a tagged item with no section, a `--local` key, and a Secure Enclave list per Mac.
  - 2026-11-19 UTC: `BackupPlannerTests` cover new, changed, renamed, removed and foreign items, and each `backupRemoved` value.
    They also cover seven malformed tagged items, a `--local` key, and a Secure Enclave list per Mac.
  - 2026-11-19 UTC: An SSH key field matches by its public key, so a private key in another text form is no change.
    A renamed Mac or a new item format writes each item once.
    A printed key, item or plan contains no private key.
- [x] 1.4 Cover removals, duplicates and the cache.
  Verify unit tests for a failed or partial CloudKit read, which removes nothing.
  Verify a unit test for a completed empty read, which removes the last key's item.
  Verify unit tests for duplicate items and for a current cache, where a run with no difference makes only the list call.
  - 2026-11-19 UTC: The same tests cover a read that did not complete, which removes nothing and shows why.
    They cover a completed empty read and a key still in the store.
    A `Key` record that could not be read keeps every shared item, and this Mac's own keys still go.
  - 2026-11-19 UTC: They cover duplicates: a slot with a current copy is not written.
    Otherwise a run writes to the copy the cache records.
    They cover a current cache with only the list call, and items read in batches of 50.
  - 2026-11-19 UTC: A plan that asks for reads returns the cache entries it has.
    An item whose read failed is left alone, and that run creates no item.
- [ ] 1.5 Add the schedule and the lease by design decisions 4 and 5.
  Verify unit tests with a fake clock for the delay, the interval and the daily run.
  Verify unit tests for a lease held by another Mac, an expired lease, and a renewal that fails mid-run.
- [ ] 1.6 Add `signd backup restore` by design decision 7.
  Verify a unit test that skips a key the store already has.
- [ ] 1.7 Report the backup in `signd status`.
  Verify a test of the JSON report's fields.

## 2. Release

- [ ] 2.1 Add the `Lease` and `Backup` record types to `cloudkit/schema.ckdb` and deploy them to production.
  Verify an export of production lists both.
- [ ] 2.2 Create the `signd` vault and a service account that can write only to it.
  Verify the account lists that vault alone.

## 3. Integration

- [ ] 3.1 Log in on one Mac.
  Verify the other Mac's `signd backup status` shows the backup on.
  Verify the vault contains one item per shared key within `backupDelay` plus a minute.
- [ ] 3.2 Delete a throwaway key.
  Verify its item lands in Recently Deleted and a foreign item in the vault is unchanged.
- [ ] 3.3 Restore the throwaway key from Recently Deleted and run `signd backup restore`.
  Verify the key signs on both Macs.

[so-004]: https://github.com/victor-software-house/swift-onepassword/releases/tag/v0.0.4
