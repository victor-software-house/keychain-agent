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
  - 2026-11-19 UTC: [CI run 44509529555][ci-69] passed with these tests at `30801d3`.
- [x] 1.5 Add the backup run, its schedule and its lease by design decisions 4 and 5.
  Verify unit tests with a fake clock for the delay, the interval and the daily run.
  Verify unit tests for a lease held by another Mac, an expired lease, and a renewal that fails mid-run.
  Verify a run end to end.
  - 2026-11-19 UTC: `BackupRunTests` cover the delay, the interval and the daily run with fixed dates and a fake clock.
    A failed run records its error and waits one interval, with no run after it until the slot comes.
  - 2026-11-19 UTC: They cover a lease held by another Mac, which stops the run with no CloudKit save and no 1Password call.
    They cover an expired lease taken over, and a late clear that leaves another Mac's newer claim.
    A renewal that fails between two create batches stops the run before the second batch.
  - 2026-11-19 UTC: One run end to end creates four items, then puts one, deletes one and creates one with no item read.
    The saved cache has each item's exact `updatedAt`, so a third run makes only the list call.
    The private key field of a created item reads back as the shared key.
  - 2026-11-19 UTC: A failed read of one item leaves that item alone and creates no item for a new key.
  - 2026-11-19 UTC: A key changed on this Mac reaches the schedule through the agent's reload request.
    The test sends that request and checks that a run is due after `backup-delay`.
  - 2026-11-19 UTC: Review fixes of the run, each with a test in `BackupRunTests`.
    `aKeyRecordWithAnotherPublicKeyGetsNoItemFromTheLocalKey` writes no item and caches nothing for a record whose public key differs from the local copy's.
    `theLeaseIsRenewedBeforeACallOnceAThirdOfItHasPassed` and `aRenewalThatFailsBeforeAPutStopsTheRunBeforeThatCall` cover the renewal inside a put group.
  - 2026-11-19 UTC: `aTokenThatDiffersFromTheStoredOneCountsAsAChange` in `BackupTests` covers the sync report that makes a backup run due on a Mac that did not log in.
    `aPutOrArchiveThatThrowsIsCountedAndTheRunGoesOn`, `aLeaseOfAnotherFormatHoldsUntilItsExpiryAndOnlyAnUnreadableOneIsFree` and `resultsAreMatchedToTheirRequestsWhateverTheOrder` cover the rest.
  - 2026-11-19 UTC: A key that 1Password's SSH Key item cannot take gets a Secure Note by design decision 2.
    `anSSHKeyItemFitsEd25519AndRSAOfTheListedSizesAndExponents` in `BackupRunTests` covers `PublicKey.fitsSSHKeyItem` at the size and exponent edges.
  - 2026-11-19 UTC: `aKeyTheSSHKeyItemCannotTakeGetsASecureNote` runs an elliptic curve key and a 1024-bit key into Secure Notes, beside two SSH Key items.
    The next run makes only the list call, and a run with no cache writes nothing.
  - 2026-11-19 UTC: `BackupPlannerTests` cover the notes.
    `anECDSAKeyAndA1024BitRSAKeyEachGetASecureNote` and `anEd25519KeyAndA2048BitRSAKeyEachGetAnSSHKeyItem` cover each item's category and fields.
  - 2026-11-19 UTC: `aSecureNoteThatHasWhatItShouldIsLeftAlone` and `aChangedSecureNoteIsPut` cover the comparison by the fingerprint of the public key field.
    They cover a note with no readable public key.
  - 2026-11-19 UTC: `aKeyWhoseItemIsInTheOtherCategoryGetsAnItemInTheRightOneAndTheOldGoes` covers a new item in the right category.
    It covers the old item's removal by each `backupRemoved` value.
  - 2026-11-19 UTC: `aOnePasswordErrorIsRecordedByItsKindAndNeverItsMessage` covers a 1Password error that echoes the private key and a host.
    The recorded result shows the call, the item and the error code, and neither value.
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
[ci-69]: https://github.com/victor-software-house/signd/actions/runs/44509529555
