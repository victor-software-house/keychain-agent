# Tasks

## 1. The binding

- [x] 1.1 Create the public `swift-onepassword` repository with a README, an AGENTS.md and VERSION 0.0.0 in its first commit, on the shared Swift template; verify its CI runs on GitHub-hosted runners.
  - 2026-11-18 UTC: [swift-onepassword] is public, and its first commit, with README.md, AGENTS.md and VERSION 0.0.0, is [99c5a8c][so-first], and it renders CI from templates v0.0.120 ([swift-onepassword#7]).  
    Its Build and test job runs on GitHub's `xcode-27` image and passed on [swift-onepassword#8].
- [x] 1.2 Write the Go shim of design decision 1 against an exact onepassword-sdk-go version, and its Swift `OnePassword` module; verify tests that open a client with a malformed token and get a typed error.
  - 2026-11-18 UTC: `core/go.mod` requires onepassword-sdk-go v0.4.1 exactly.  
    [`malformedTokenIsAnAuthenticationError`][so-client-tests] opens a client with a malformed token and gets `OnePasswordError` of kind `authentication`; it passed in the check step of [swift-onepassword#8].
- [x] 1.3 Build the XCFramework in the release job and publish it with its checksum, and point `binaryTarget` at it. Verify that a sample package resolves and links it on a GitHub-hosted runner, and record the binary size and first-client start-up time in the release notes.
  - 2026-11-18 UTC: the Core workflow publishes `COnePassword.xcframework.zip` to release [core-92966556d452][so-core], and `Package.swift` points its `binaryTarget` there with the zip's checksum.  
    The release workflow's Consumer package job resolves and links a released version in a sample package on `xcode-27`.
  - The [0.0.2 release notes][so-0.0.2] record the zip, 26.1 MB, and a cold first client, 2,265 ms and a 170 MB resident peak, from one benchmark sample.
- [x] 1.4 Add a live test that lists vaults, items and one SSH Key item with a test service account from the repository's secrets; verify it passes in the release job.
  - 2026-11-18 UTC: `LiveTests` lists the test vault, its items and the `test-key` SSH Key item with `OP_TEST_SERVICE_ACCOUNT_TOKEN`.  
    The Live 1Password job of [release run 44232571722][so-release-run] passed.

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
  - 2026-11-18 00:50 UTC, signd 0.0.6: on both Macs, the dotfiles signed signd in with a service account token, and signd synced an RSA key item with a `hosts` field from the vault.  
    Each Mac routed that host to the synced key, and `git ls-remote` through it returned HEAD after the imported copy of the key was deleted.
  - 2026-11-18 00:51 UTC: a change to the item's `hosts` field reached the two Macs 2 min 48 s and 4 min 3 s later, inside the 5-minute interval.
  - Not verified: replacing the key itself, with a login through the new key, because that host needs a new key registered by hand.
- [ ] 5.2 Run one Mac for a day and read its request count with the account's rate-limit report; verify it stays within one read per interval plus the fetches for changed items.

## Workflow follow-up

- Archive this change after the `wrapped-keys` change.

[signd#16]: https://github.com/victor-software-house/signd/pull/16
[swift-onepassword]: https://github.com/victor-software-house/swift-onepassword
[so-first]: https://github.com/victor-software-house/swift-onepassword/commit/99c5a8c073ad83769efb6b1b64fe11e2bb36d443
[swift-onepassword#7]: https://github.com/victor-software-house/swift-onepassword/pull/7
[swift-onepassword#8]: https://github.com/victor-software-house/swift-onepassword/pull/8
[so-client-tests]: https://github.com/victor-software-house/swift-onepassword/blob/a2e3d08281d1d57e79cb133a1be513268a31c967/Tests/OnePasswordTests/ClientTests.swift
[so-core]: https://github.com/victor-software-house/swift-onepassword/releases/tag/core-92966556d452
[so-0.0.2]: https://github.com/victor-software-house/swift-onepassword/releases/tag/v0.0.2
[so-release-run]: https://github.com/victor-software-house/swift-onepassword/actions/runs/44232571722
[sync-tests]: ../../../Tests/SigndTests/SyncTests.swift
