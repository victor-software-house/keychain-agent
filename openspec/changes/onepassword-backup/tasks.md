# Tasks

## 1. Code

- [ ] 1.1 Add batch create and delete, `put` and `archive` to `swift-onepassword`; verify its live tests create, update, archive and delete an item in its test vault.
- [ ] 1.2 Store the token by design decision 6, with `signd backup login` and `logout`; verify unit tests that no file, argument or log holds it.
- [ ] 1.3 Plan a run by design decisions 1 to 3; verify unit tests of the plan for new, changed, removed and foreign items, and for each `backupRemoved` value.
- [ ] 1.4 Add the schedule and the lease by design decisions 4 and 5; verify unit tests with a fake clock for the delay, the interval, the daily run, a held lease and an expired one.
- [ ] 1.5 Add `signd backup restore` by design decision 7; verify a unit test that skips a key the store holds.
- [ ] 1.6 Report the backup in `signd status`; verify a test of the JSON report's fields.

## 2. Release

- [ ] 2.1 Deploy the `Lease` record type to production; verify an export of production lists it.
- [ ] 2.2 Create the `signd` vault and a service account that can write only to it; verify the account lists that vault alone.

## 3. Integration

- [ ] 3.1 Log in on one Mac; verify the other Mac's `signd backup status` shows the backup on, and the vault holds one item per shared key within `backupDelay` plus a minute.
- [ ] 3.2 Delete a throwaway key; verify its item lands in Recently Deleted and a foreign item in the vault is unchanged.
- [ ] 3.3 Restore the throwaway key from Recently Deleted and run `signd backup restore`; verify the key signs on both Macs.
