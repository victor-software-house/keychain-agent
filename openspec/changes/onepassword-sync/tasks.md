# Tasks

## 1. The binding

- [ ] 1.1 Create the public `swift-onepassword` repository with a README, an AGENTS.md and VERSION 0.0.0 in its first commit, on the shared Swift template; verify its CI runs on GitHub-hosted runners.
- [ ] 1.2 Write the Go shim of design decision 1 against an exact onepassword-sdk-go version, and its Swift `OnePassword` module; verify tests that open a client with a malformed token and get a typed error.
- [ ] 1.3 Build the XCFramework in the release job and publish it with its checksum, and point `binaryTarget` at it. Verify that a sample package resolves and links it on a GitHub-hosted runner, and record the binary size and first-client start-up time in the release notes.
- [ ] 1.4 Add a live test that lists vaults, items and one SSH Key item with a test service account from the repository's secrets; verify it passes in the release job.

## 2. Token and sync

- [ ] 2.1 Implement `signd login` and `signd logout`; verify the token scenarios with the live test account.
- [ ] 2.2 Implement the check of design decision 5, with item selection and naming from decision 3; verify unit tests against a recorded 1Password fake for add, replace, delete, the `macs` field and the one-read case.
- [ ] 2.3 Implement the schedule and failures of decisions 6 and 7, and `signd sync`; verify unit tests with an injected clock for phase, jitter, backoff and the rate-limit wait.
- [ ] 2.4 Read the `signd` note and merge it under local settings; verify the fleet-interval scenario against the fake.
- [ ] 2.5 Show sync state in `signd status`; verify `--json` carries the last result, the next attempt and every skipped item.

## 3. SSH routing

- [ ] 3.1 Write `~/.ssh/signd/config` and the public files atomically, with host pattern checks; verify the `ssh-routing` scenarios with `ssh -G` in `mise run ci:e2e`.

## 4. Documentation

- [ ] 4.1 Document the vault, the service account, the item fields and the `signd` note in README.md; verify each documented command runs as written.

## 5. Integration

- [ ] 5.1 Migrate each Mac by the design's migration plan; verify that replacing a key in 1Password reaches both Macs within one interval, with a login through the new key.
- [ ] 5.2 Run one Mac for a day and read its request count with the account's rate-limit report; verify it stays within one read per interval plus the fetches for changed items.

## Workflow follow-up

- Archive this change after the `wrapped-keys` change.
