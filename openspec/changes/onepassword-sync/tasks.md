# Tasks

## 1. The binding

- [ ] 1.1 Create the public `swift-onepassword` repository with a README, an AGENTS.md and VERSION 0.0.0 in its first commit, on the shared Swift template; verify its CI runs on GitHub-hosted runners.
- [ ] 1.2 Write the Go shim of design decision 1 against an exact onepassword-sdk-go version, and its Swift `OnePassword` module; verify tests that open a client with a malformed token and get a typed error.
- [ ] 1.3 Build the XCFramework in the release job and publish it with its checksum, and point `binaryTarget` at it. Verify that a sample package resolves and links it on a GitHub-hosted runner, and record the binary size and first-client start-up time in the release notes.
- [ ] 1.4 Add a live test that lists vaults, items and one SSH Key item with a test service account from the repository's secrets; verify it passes in the release job.

## 2. Token and sync

- [x] 2.1 Implement `signd login` and `signd logout`; verify the token scenarios with the live test account.
  - 2026-11-18 00:20 (UTC): on a signed Mac with signd 0.0.5 ([PR 16][signd#16]).  
    A malformed token piped to `signd login` exits 1 with "1Password refused the token: ... service account token had invalid format", and `signd status` stays not signed in.  
    The test account's token signs in ("the token reads 1 vault").
  - 2026-11-18 00:20 (UTC): in the same run, `signd sync` reports "ok: 3 requests, 1 items fetched, added test-key".  
    `ssh-add -l` through the socket lists test-key (ED25519), `~/.ssh/signd/config` gets a Host `example.invalid` block, and `ssh-keygen -Y sign` with `test-key.pub` exits 0.
  - 2026-11-18 00:20 (UTC): in the same run, `signd logout` prints "signed out; removed 1 synced key".  
    The key and its Host block are gone, local keys stay, and the state folder is empty.  
    Not verified: a revoked token.
- [x] 2.2 Implement the check of design decision 5, with item selection and naming from decision 3; verify unit tests against a recorded 1Password fake for add, replace, delete, the `macs` field and the one-read case.
  - 2026-11-17 (UTC): on a Mac, [`Checks`][sync-tests] passed against a recorded fake: add, replace in place, hosts-only change, rename, delete, archived item, deleted vault, `macs`, bad host and name taken. Unchanged vaults cost 1 request and no fetch ([PR 16][signd#16]).
- [x] 2.3 Implement the schedule and failures of decisions 6 and 7, and `signd sync`; verify unit tests with an injected clock for phase, jitter, backoff and the rate-limit wait.
  - 2026-11-17 (UTC): on a Mac, `Schedule` passed with an injected clock and random source.  
    It covers the phase, the 0.8 to 1.2 factor, backoff up to the interval, and rate-limit waits of 1 h, 2 h and 4 h.  
    A refused token is not retried ([PR 16][signd#16]).
- [x] 2.6 Open the client in the background at agent start and keep it. Verify with a test that list and sign requests answer within the same p99 as with no token stored, both while the client starts and while a check runs.
  - 2026-11-17 (UTC): on a Mac, [`RequestsNeverWait`][sync-tests] kept list and sign p99 within 3 times the no-token p99 plus 5 ms, while the client took 2 s to open and while each call took 2 s. It failed when a request awaited a check.
- [x] 2.4 Read the `signd` note and merge it under local settings; verify the fleet-interval scenario against the fake.
  - 2026-11-17 (UTC): on a Mac, `theNoteSetsFleetSettings` passed against the fake: a note interval of `60m` reaches the status unless a local value is set, and a bad note value is reported.
- [x] 2.5 Show sync state in `signd status`; verify `--json` carries the last result, the next attempt and every skipped item.
  - 2026-11-17 (UTC): on a Mac, `statusJSONCarriesTheLastResultTheNextAttemptAndEverySkippedItem` passed on the encoded status. The command was built and its help read; a run against an agent is left to the hardware run.

## 3. SSH routing

- [x] 3.1 Write `~/.ssh/signd/config` and the public files atomically, with host pattern checks; verify the `ssh-routing` scenarios with `ssh -G` in `mise run ci:e2e`.
  - 2026-11-17 (UTC): `mise run ci:e2e` passed on a Mac ([PR 16][signd#16]).  
    `ssh -G` showed the socket and key files for shared and wildcard hosts, and the files had modes 700, 600 and 644.  
    A bad pattern got no block, and a key's last host was removed.

## 4. Documentation

- [x] 4.1 Document the vault, the service account, the item fields and the `signd` note in README.md; verify each documented command runs as written.
  - 2026-11-18 00:20 (UTC): on a signed Mac with signd 0.0.5, in the same run as 2.1, every command in the README's "Keys from 1Password" block ran as written ([PR 16][signd#16]).  
    That includes `signd config set interval 10m`, after which `signd status` shows "10m (local)", and `signd config unset interval`, which reverts it.

## 5. Integration

- [ ] 5.1 Migrate each Mac by the design's migration plan; verify that replacing a key in 1Password reaches both Macs within one interval, with a login through the new key.
- [ ] 5.2 Run one Mac for a day and read its request count with the account's rate-limit report; verify it stays within one read per interval plus the fetches for changed items.

## Workflow follow-up

- Archive this change after the `wrapped-keys` change.

[signd#16]: https://github.com/victor-software-house/signd/pull/16
[sync-tests]: ../../../Tests/SigndTests/SyncTests.swift
