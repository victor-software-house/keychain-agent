# Tasks

## 1. Plan

- [x] 1.1 Archive the `onepassword-sync` change, with its two open integration tasks marked dropped; verify `mise run specs` passes.
  - 2026-11-18 UTC: archived as `2026-11-18-onepassword-sync`.
    The archive adds the `onepassword-sync` and `ssh-routing` specs that this change then modifies.
    `mise run specs` passed 9 of 9.

## 2. Store and records

- [x] 2.1 Add the device key of design decision 2 to `KeyStore`.
  Remove the token store.
  Give shared keys the source `icloud` and a record name.
  Verify that a key item written by an older release still decodes.
  - 2026-11-18 UTC: `anItemAnOlderReleaseWroteStillDecodes` decodes a 1Password-era item with no record name and not shared.
    `aSharedKeySurvivesAnEncodeAndDecode` passed.
    Both ran in `swift test` on a Mac with macOS 27.2.1 and Xcode 27.2, 98 of 98 tests, five runs in a row.
- [x] 2.2 Write the `Key` and `Device` payloads of decision 1.
  Verify an encode and decode keeps every field.
  Verify a payload of another format is reported, not read.
  - 2026-11-18 UTC: `payloadsKeepEveryFieldThroughAnEncodeAndDecode` and `aPayloadOfAnotherFormatIsReportedAndNotRead` passed in the same runs.
- [x] 2.3 Write the CloudKit store with the timeouts and the error mapping of decision 8.
  Verify unit tests that map each CloudKit error code to the action signd takes.
  - 2026-11-18 UTC: `eachCloudKitErrorMapsToItsKind` covers 15 codes; the retry-after, partial-failure and timeout tests passed in the same runs.

## 3. Checks and the schedule

- [x] 3.1 Implement the check of decision 6 against a CloudKit stand-in.
  Verify tests for a new key, a deleted record, and a key waiting for this device.
  Verify tests for a name a local key has, and sealing to a new device.
  Verify also a removed device, publishing this device's record, an expired token and a deleted zone.
  - 2026-11-18 UTC: each has a test in `SyncTests.swift`, run against `FakeCloud` with two or three devices on one account; all passed in the same runs.
- [x] 3.2 Verify that a check with no change makes one request.
  - 2026-11-18 UTC: `anUnchangedZoneCostsOneRequest` passed: the second check reads back this device's own record, two requests, and the third makes one.
- [x] 3.3 Implement the schedule of decisions 7 and 8 and the push hint.
  Verify tests with an injected clock for the interval, the backoff, a retry-after time and a push during a backoff.
  - 2026-11-18 UTC: the schedule tests and `aPushStartsACheckUnlessTheServiceIsBackingOff` passed; a race they found, a finished check whose handle stayed set, is fixed.
- [x] 3.4 Verify that list and sign requests keep their p99 while a check waits on a slow store.
  - 2026-11-18 UTC: `listAndSignKeepTheirP99WhileACheckWaitsOnASlowCloud` passed with each CloudKit call taking 2 s.
- [x] 3.5 Read the iCloud entitlement from the signature, as decision 10 says; verify `mise run ci:e2e` with the unsigned build reports sync off and serves keys.
  - 2026-11-18 UTC: `mise run ci:e2e` passed on that Mac; the unsigned agent's status reports `off in this build`.

## 4. Commands

- [x] 4.1 Share by default on `key create` and `key import`, with `--local`.
  Add `key share`, the shared `key delete`, `device list` and `device remove`.
  Remove `login` and `logout`.
  Verify the command scenarios of the `icloud-sync` spec on two Macs.
  - 2026-11-18 UTC: on both Macs with 0.0.8, `key create ci-check --type ed25519` on Mac A was listed on Mac B with source `icloud` 2.94 s later.
    `ssh-keygen -Y sign` with it through Mac B's agent verified.
    `key import old-check --local` stayed off Mac B, and `key share` of Mac B's Secure Enclave key failed with exit 1.
  - The shared delete left Mac B 3.69 s later, `signd sync` reported 1 request, and `login` and `logout` are gone from `signd --help`.
    `device remove` ran only against `FakeCloud` in `SyncTests`, since removing either real Mac would end its sharing.
- [x] 4.2 Run the agent's `NSApplication` and pass pushes to the sync service; verify on a Mac that `signd status` shows a push received.
  - 2026-11-18 UTC: during the hour run of task 6.2, `signd status` showed a push received on each Mac.
    The last one came at 17:06:59 UTC on Mac A and at 17:08:33 UTC on Mac B.
- [x] 4.3 Show the sync in `signd status`; verify `--json` carries the account state, the last result, the next check and every waiting and skipped key.
  - 2026-11-18 UTC: `statusJSONCarriesTheStateTheLastResultTheNextCheckAndEverySkippedKey` passed in the `swift test` runs of task 2.1.

## 5. Release and documentation

- [x] 5.1 Sign the release with the profile's iCloud and push entitlements; verify `codesign -d --entitlements -` on the released app lists them.
  - 2026-11-18 UTC: the [0.0.8 release][rel-008] attaches `signd.pkg`, signed for Developer ID Installer and notarized, and `spctl -a -t install` accepts it.
    `codesign -d --entitlements -` on its `Signd.app` lists CloudKit in `icloud-services`, the one container, the Production environment, `aps-environment` production and the keychain access group.
- [x] 5.2 Drop `swift-onepassword` and the 1Password test secret from the template answers; verify CI passes with neither.
  - 2026-11-18 UTC: `main` has no `OnePassword` import and no `swift-onepassword` package, and `ci_secrets` is empty.
    The repository secret `OP_TEST_SERVICE_ACCOUNT_TOKEN` is deleted, and CI passed on [#44][pr-44] with neither.
- [x] 5.3 Rewrite the README's 1Password sections for iCloud; verify each documented command runs as written.
  - 2026-11-18 UTC: the README has no 1Password section left.
    Each command in its Keys, Keys through iCloud and Settings sections ran on both Macs.
    `key share` of a `--local` key reached Mac B in 1.89 s, and `--host git.example.com` reached Mac B's `~/.ssh/signd/config` in 1.11 s.
    `device remove` was not run, as task 4.1 says.
- [x] 5.4 Deploy `cloudkit/schema.ckdb` to the production environment; verify an export of production lists the `Device` type.
  - 2026-11-18 UTC: the CloudKit console's deploy created `Device` and its index and updated the three security roles for it; `cktool export-schema --environment production` lists `Device`, `Key`, `Mac` and `Users`.

## 6. Integration

- [x] 6.1 Migrate both Macs by the design's migration plan.
  Verify a key shared on one Mac signs on the other.
  Record the seconds from the share to the other Mac's list, in both directions.
- [x] 6.2 Run both Macs for an hour; verify no throttle and every change seen on the other Mac within 5 seconds.
  - 2026-11-18 UTC: both Macs run 0.0.8 through the cask.
    Step 1 did not hold on Mac A, whose key items had left the `signd` vault before the upgrade.
    So Mac A's store had no key.

  - A work key was imported on Mac A from its 1Password item through stdin, and shared by default.
    Mac B listed it 2.78 s after the import began.
    `ssh -T` to that key's Git host through `~/.ssh/signd.sock` authenticated on both Macs.

  - Six rounds used throwaway keys, each imported on one Mac and deleted 3 s later.
    The other Mac polled every 0.2 s, and the 0.046 s clock offset is removed:

    | From | Share, seconds | Delete, seconds |
    |:--|:--|:--|
    | Mac A | 1.11, 1.14, 1.03 | 2.16, 2.54, 2.23 |
    | Mac B | 0.88, 0.92, 0.84 | 0.74, 0.72, 0.91 |

  - For steps 4 and 5, the `signd` vault read is deleted, and the `signd` service account is revoked in 1Password.

  - 2026-11-18 UTC: from 16:07 to 17:07 UTC, a shared key was imported every 2 minutes, on each Mac in turn.
    Each one was deleted 3 s later.
    All 31 rounds saw both changes on the other Mac, with no timeout.
    Every check was `ok` at the 2 s interval, so nothing was throttled.

  - Seconds from each change to the other Mac's list:

    | Change | Median, seconds | p95, seconds | Max, seconds |
    |:--|:--|:--|:--|
    | Share | 2.24 | 2.95 | 3.17 |
    | Delete | 1.68 | 2.75 | 2.77 |

[rel-008]: https://github.com/victor-software-house/signd/releases/tag/v0.0.8
[pr-44]: https://github.com/victor-software-house/signd/pull/44
