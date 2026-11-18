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

- [ ] 4.1 Share by default on `key create` and `key import`, with `--local`.
  Add `key share`, the shared `key delete`, `device list` and `device remove`.
  Remove `login` and `logout`.
  Verify the command scenarios of the `icloud-sync` spec on two Macs.
- [ ] 4.2 Run the agent's `NSApplication` and pass pushes to the sync service; verify on a Mac that `signd status` shows a push received.
- [x] 4.3 Show the sync in `signd status`; verify `--json` carries the account state, the last result, the next check and every waiting and skipped key.
  - 2026-11-18 UTC: `statusJSONCarriesTheStateTheLastResultTheNextCheckAndEverySkippedKey` passed in the `swift test` runs of task 2.1.

## 5. Release and documentation

- [ ] 5.1 Sign the release with the profile's iCloud and push entitlements; verify `codesign -d --entitlements -` on the released app lists them.
- [ ] 5.2 Drop `swift-onepassword` and the 1Password test secret from the template answers; verify CI passes with neither.
- [ ] 5.3 Rewrite the README's 1Password sections for iCloud; verify each documented command runs as written.
- [x] 5.4 Deploy `cloudkit/schema.ckdb` to the production environment; verify an export of production lists the `Device` type.
  - 2026-11-18 UTC: the CloudKit console's deploy created `Device` and its index and updated the three security roles for it; `cktool export-schema --environment production` lists `Device`, `Key`, `Mac` and `Users`.

## 6. Integration

- [ ] 6.1 Migrate both Macs by the design's migration plan.
  Verify a key shared on one Mac signs on the other.
  Record the seconds from the share to the other Mac's list, in both directions.
- [ ] 6.2 Run both Macs for an hour; verify no throttle and every change seen on the other Mac within 5 seconds.
