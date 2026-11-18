# Tasks

## 1. Plan

- [x] 1.1 Archive the `onepassword-sync` change, with its two open integration tasks marked dropped; verify `mise run specs` passes.
  - 2026-11-18 UTC: archived as `2026-11-18-onepassword-sync`, which adds the `onepassword-sync` and `ssh-routing` specs that this change then modifies; `mise run specs` passed 9 of 9.

## 2. Store and records

- [ ] 2.1 Add the device key of design decision 2 to `KeyStore`, remove the token store, and give shared keys the source `icloud` and a record name; verify that a key item written by an older release still decodes.
- [ ] 2.2 Write the `Key` and `Device` payloads of decision 1; verify an encode and decode keeps every field, and a payload of another format is reported, not read.
- [ ] 2.3 Write the CloudKit store with the timeouts and error kinds of decision 8; verify unit tests that map each CloudKit error to its kind.

## 3. The check and its schedule

- [ ] 3.1 Implement the check of decision 6 against a CloudKit stand-in; verify tests for a new key, a replaced key, a deleted record, a key waiting for this device, a name a local key has, sealing to a new device, a removed device, publishing this device's record, an expired token and a deleted zone.
- [ ] 3.2 Verify that a check with no change makes one request.
- [ ] 3.3 Implement the schedule of decisions 7 and 8 and the push hint; verify tests with an injected clock for the interval, the backoff, a retry-after time and a push during a backoff.
- [ ] 3.4 Verify that list and sign requests keep their p99 while a check waits on a slow store.
- [ ] 3.5 Read the iCloud entitlement from the signature, as decision 10 says; verify `mise run ci:e2e` with the unsigned build reports sync off and serves keys.

## 4. Commands

- [ ] 4.1 Share by default on `key create` and `key import`, with `--local`; add `key share`, the shared `key delete`, `device list`, `device remove`; remove `login` and `logout`; verify the command scenarios of the `icloud-sync` spec on two Macs.
- [ ] 4.2 Run the agent's `NSApplication` and pass pushes to the sync service; verify on a Mac that `signd status` shows a push received.
- [ ] 4.3 Show the sync in `signd status`; verify `--json` carries the account state, the last result, the next check and every waiting and skipped key.

## 5. Release and documentation

- [ ] 5.1 Sign the release with the profile's iCloud and push entitlements; verify `codesign -d --entitlements -` on the released app lists them.
- [ ] 5.2 Drop `swift-onepassword` and the 1Password test secret from the template answers; verify CI passes with neither.
- [ ] 5.3 Rewrite the README's 1Password sections for iCloud; verify each documented command runs as written.

## 6. Integration

- [ ] 6.1 Migrate both Macs by the design's migration plan; verify a key shared on one Mac signs on the other, and record the seconds from the share to the other Mac's list, in both directions.
- [ ] 6.2 Run both Macs for an hour; verify no throttle and every change seen on the other Mac within 5 seconds.
